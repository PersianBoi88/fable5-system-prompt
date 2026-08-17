/**
 * Local smart home dashboard - backend
 *
 * Design constraints, in priority order:
 *
 *  1. MQTT credentials never reach the browser. The browser talks to this
 *     server; only this server talks to the broker. A compromised phone
 *     session cannot be replayed against the broker directly.
 *
 *  2. Minimal dependency surface. This process can open a front door, so the
 *     only runtime dependency is the MQTT client. Sessions, hashing, CSRF and
 *     the event stream all use Node built-ins. Server-Sent Events are used
 *     instead of WebSockets specifically to avoid pulling in `ws` - state push
 *     is one-directional anyway.
 *
 *  3. The lock is not just another device. Network-level access (being on the
 *     tailnet) is explicitly NOT sufficient to operate it: an unlocked phone
 *     already satisfies that. Lock operations require a separate PIN, entered
 *     per operation, rate-limited, and written to an audit log.
 *
 *  4. Binds to loopback by default. Exposure is Tailscale's job via
 *     `tailscale serve`, which also supplies TLS. Nothing listens on the LAN.
 */

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
    scryptSync, randomBytes, timingSafeEqual, createHmac, randomUUID,
} from 'node:crypto';
import mqtt from 'mqtt';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const CONFIG_PATH = process.env.DASHBOARD_CONFIG
    || 'C:\\ProgramData\\xfinity-home\\dashboard.json';
const AUDIT_PATH = process.env.DASHBOARD_AUDIT
    || 'C:\\ProgramData\\xfinity-home\\dashboard-audit.log';

// --- Tunables --------------------------------------------------------------
const SESSION_TTL_MS      = 12 * 60 * 60 * 1000;  // 12h
const PIN_WINDOW_MS       = 30 * 1000;            // PIN is valid for one op, briefly
const MAX_LOGIN_FAILS     = 5;
const MAX_PIN_FAILS       = 5;
const LOCKOUT_MS          = 15 * 60 * 1000;
const STALE_DEVICE_MS     = 6 * 60 * 60 * 1000;   // flag sensors silent this long

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
let config;
try {
    config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
} catch (err) {
    console.error(`Cannot read config at ${CONFIG_PATH}: ${err.message}`);
    console.error('Run scripts\\06-Setup-Dashboard.ps1 to generate it.');
    process.exit(1);
}

for (const required of ['users', 'mqtt', 'sessionSecret']) {
    if (!config[required]) {
        console.error(`Config is missing required key: ${required}`);
        process.exit(1);
    }
}

const LOCK_ENABLED = Boolean(config.lock && config.lock.commandTopic && config.lockPin);
if (config.lock && config.lock.commandTopic && !config.lockPin) {
    console.warn('Lock topic configured but no lockPin set - lock control is DISABLED.');
}

// ---------------------------------------------------------------------------
// Password hashing
// ---------------------------------------------------------------------------
function hashSecret(secret, saltHex) {
    // scrypt with the Node defaults for N/r/p, 64-byte output.
    return scryptSync(secret, Buffer.from(saltHex, 'hex'), 64).toString('hex');
}

function verifySecret(secret, saltHex, expectedHex) {
    let actual;
    try {
        actual = Buffer.from(hashSecret(secret, saltHex), 'hex');
    } catch {
        return false;
    }
    const expected = Buffer.from(expectedHex, 'hex');
    // timingSafeEqual throws on length mismatch, which would itself leak.
    if (actual.length !== expected.length) return false;
    return timingSafeEqual(actual, expected);
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------
/** @type {Map<string, {user: string, csrf: string, expires: number, pinOkUntil: number, pinFails: number, lockedUntil: number}>} */
const sessions = new Map();

const loginFailures = new Map(); // key -> {count, lockedUntil}

function signSession(id) {
    const mac = createHmac('sha256', config.sessionSecret).update(id).digest('hex');
    return `${id}.${mac}`;
}

function verifySessionCookie(value) {
    if (typeof value !== 'string' || !value.includes('.')) return null;
    const idx = value.lastIndexOf('.');
    const id = value.slice(0, idx);
    const mac = value.slice(idx + 1);
    const expected = createHmac('sha256', config.sessionSecret).update(id).digest('hex');
    const a = Buffer.from(mac, 'hex');
    const b = Buffer.from(expected, 'hex');
    if (a.length !== b.length || !timingSafeEqual(a, b)) return null;
    return id;
}

function createSession(user) {
    const id = randomUUID();
    const session = {
        user,
        csrf: randomBytes(32).toString('hex'),
        expires: Date.now() + SESSION_TTL_MS,
        pinOkUntil: 0,
        pinFails: 0,
        lockedUntil: 0,
    };
    sessions.set(id, session);
    return { id, session };
}

function getSession(req) {
    const cookies = parseCookies(req.headers.cookie || '');
    const raw = cookies.sid;
    if (!raw) return null;
    const id = verifySessionCookie(raw);
    if (!id) return null;
    const session = sessions.get(id);
    if (!session) return null;
    if (session.expires < Date.now()) {
        sessions.delete(id);
        return null;
    }
    return { id, session };
}

function parseCookies(header) {
    const out = {};
    for (const part of header.split(';')) {
        const i = part.indexOf('=');
        if (i < 0) continue;
        out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
    }
    return out;
}

// Sweep expired sessions rather than letting the map grow unbounded.
setInterval(() => {
    const now = Date.now();
    for (const [id, s] of sessions) if (s.expires < now) sessions.delete(id);
    for (const [k, v] of loginFailures) if (v.lockedUntil && v.lockedUntil < now) loginFailures.delete(k);
}, 60_000).unref();

// ---------------------------------------------------------------------------
// Audit log
// ---------------------------------------------------------------------------
function audit(event, detail) {
    const line = JSON.stringify({ ts: new Date().toISOString(), event, ...detail }) + '\n';
    fs.appendFile(AUDIT_PATH, line, (err) => {
        if (err) console.error(`Audit write failed: ${err.message}`);
    });
    console.log(`[audit] ${event} ${JSON.stringify(detail)}`);
}

// ---------------------------------------------------------------------------
// MQTT + state
// ---------------------------------------------------------------------------
const state = {
    zigbeeDevices: [],           // from bridge/devices
    values: new Map(),           // topic -> {payload, at}
    bridgeOnline: false,
    connected: false,
};

const sseClients = new Set();

function broadcast(type, data) {
    const frame = `event: ${type}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const res of sseClients) {
        try { res.write(frame); } catch { sseClients.delete(res); }
    }
}

const mqttUrl = `mqtt://${config.mqtt.host}:${config.mqtt.port}`;
const client = mqtt.connect(mqttUrl, {
    username: config.mqtt.user,
    password: config.mqtt.password,
    clientId: `dashboard-${randomBytes(4).toString('hex')}`,
    reconnectPeriod: 5000,
});

client.on('connect', () => {
    state.connected = true;
    console.log(`Connected to broker at ${mqttUrl}`);
    client.subscribe([
        'zigbee2mqtt/#',
        `${config.zwavePrefix || 'zwave'}/#`,
    ], (err) => {
        if (err) console.error(`Subscribe failed: ${err.message}`);
    });
    broadcast('status', { connected: true });
});

client.on('error', (err) => console.error(`MQTT error: ${err.message}`));
client.on('close', () => {
    state.connected = false;
    broadcast('status', { connected: false });
});

client.on('message', (topic, payloadBuf) => {
    const raw = payloadBuf.toString();
    let payload = raw;
    try { payload = JSON.parse(raw); } catch { /* plain string payload */ }

    if (topic === 'zigbee2mqtt/bridge/devices') {
        state.zigbeeDevices = Array.isArray(payload) ? payload : [];
        broadcast('devices', state.zigbeeDevices);
        return;
    }

    if (topic === 'zigbee2mqtt/bridge/state') {
        const s = typeof payload === 'object' && payload ? payload.state : payload;
        state.bridgeOnline = s === 'online';
        broadcast('status', { bridgeOnline: state.bridgeOnline });
        return;
    }

    // Ignore the rest of the bridge namespace - it is chatty and not useful here.
    if (topic.startsWith('zigbee2mqtt/bridge/')) return;

    state.values.set(topic, { payload, at: Date.now() });
    broadcast('value', { topic, payload, at: Date.now() });
});

// ---------------------------------------------------------------------------
// State snapshot for the client
// ---------------------------------------------------------------------------
function buildSnapshot() {
    const now = Date.now();

    const devices = state.zigbeeDevices
        .filter((d) => d && d.type !== 'Coordinator')
        .map((d) => {
            const topic = `zigbee2mqtt/${d.friendly_name}`;
            const entry = state.values.get(topic);
            const v = entry?.payload ?? {};
            const at = entry?.at ?? null;
            return {
                id: d.ieee_address,
                name: d.friendly_name,
                model: d.definition?.model ?? d.model_id ?? 'unknown',
                vendor: d.definition?.vendor ?? d.manufacturer ?? '',
                supported: Boolean(d.supported),
                powerSource: d.power_source ?? '',
                state: typeof v === 'object' ? v : { value: v },
                lastSeen: at,
                stale: at !== null && (now - at) > STALE_DEVICE_MS,
            };
        })
        .sort((a, b) => a.name.localeCompare(b.name));

    // Z-Wave values are exposed as a flat topic tree; the frontend renders the
    // lock specially and lists the rest raw.
    const prefix = `${config.zwavePrefix || 'zwave'}/`;
    const zwave = [];
    for (const [topic, entry] of state.values) {
        if (!topic.startsWith(prefix)) continue;
        zwave.push({
            topic,
            short: topic.slice(prefix.length),
            value: entry.payload?.value ?? entry.payload,
            at: entry.at,
        });
    }

    let lock = null;
    if (config.lock?.stateTopic) {
        const entry = state.values.get(config.lock.stateTopic);
        const rawValue = entry ? (entry.payload?.value ?? entry.payload) : null;
        lock = {
            configured: true,
            controllable: LOCK_ENABLED,
            name: config.lock.name || 'Front door',
            raw: rawValue,
            locked: interpretLock(rawValue),
            lastSeen: entry?.at ?? null,
        };
    }

    return {
        connected: state.connected,
        bridgeOnline: state.bridgeOnline,
        devices,
        zwave: zwave.sort((a, b) => a.short.localeCompare(b.short)),
        lock,
        cameras: (config.cameras || []).map((c) => ({ name: c.name, url: c.url })),
        serverTime: now,
    };
}

/**
 * Z-Wave Door Lock CC reports currentMode as a numeric enum where 255 is
 * "secured" and 0 is "unsecured", but zwave-js-ui can be configured to publish
 * booleans or label strings instead. Handle all three rather than assuming.
 */
function interpretLock(v) {
    if (v === null || v === undefined) return null;
    if (typeof v === 'boolean') return v;
    if (typeof v === 'number') return v === 255 || v === 1;
    if (typeof v === 'string') {
        const s = v.trim().toLowerCase();
        if (['true', 'locked', 'secured', '255'].includes(s)) return true;
        if (['false', 'unlocked', 'unsecured', '0'].includes(s)) return false;
    }
    return null;
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------
function send(res, status, body, headers = {}) {
    const payload = typeof body === 'string' ? body : JSON.stringify(body);
    res.writeHead(status, {
        'Content-Type': typeof body === 'string' ? 'text/html; charset=utf-8' : 'application/json',
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY',
        'Referrer-Policy': 'no-referrer',
        // Self-contained page: no external origins are permitted at all.
        // frame-src allows the go2rtc camera embeds.
        'Content-Security-Policy':
            "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; "
            + "img-src 'self' data: http://127.0.0.1:1984; frame-src http://127.0.0.1:1984; "
            + "connect-src 'self'; base-uri 'none'; form-action 'none'",
        ...headers,
    });
    res.end(payload);
}

async function readJson(req, limitBytes = 8192) {
    return await new Promise((resolve, reject) => {
        let size = 0;
        const chunks = [];
        req.on('data', (c) => {
            size += c.length;
            if (size > limitBytes) {
                reject(new Error('payload too large'));
                req.destroy();
                return;
            }
            chunks.push(c);
        });
        req.on('end', () => {
            try { resolve(JSON.parse(Buffer.concat(chunks).toString() || '{}')); }
            catch { reject(new Error('invalid JSON')); }
        });
        req.on('error', reject);
    });
}

function clientKey(req) {
    return req.socket.remoteAddress || 'unknown';
}

function requireSession(req, res) {
    const found = getSession(req);
    if (!found) {
        send(res, 401, { error: 'not authenticated' });
        return null;
    }
    return found;
}

function requireCsrf(req, res, session) {
    const token = req.headers['x-csrf-token'];
    if (typeof token !== 'string' || token !== session.csrf) {
        send(res, 403, { error: 'bad CSRF token' });
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------
const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const route = url.pathname;

    try {
        // --- static ---------------------------------------------------------
        if (req.method === 'GET' && (route === '/' || route === '/index.html')) {
            const html = fs.readFileSync(path.join(__dirname, 'public', 'index.html'), 'utf8');
            return send(res, 200, html);
        }

        // --- login ----------------------------------------------------------
        if (req.method === 'POST' && route === '/api/login') {
            const key = clientKey(req);
            const fail = loginFailures.get(key);
            if (fail?.lockedUntil > Date.now()) {
                const secs = Math.ceil((fail.lockedUntil - Date.now()) / 1000);
                audit('login.lockout', { ip: key });
                return send(res, 429, { error: `too many attempts, retry in ${secs}s` });
            }

            const body = await readJson(req);
            const user = config.users.find((u) => u.username === body.username);
            const ok = user && typeof body.password === 'string'
                && verifySecret(body.password, user.salt, user.hash);

            if (!ok) {
                const rec = loginFailures.get(key) || { count: 0, lockedUntil: 0 };
                rec.count += 1;
                if (rec.count >= MAX_LOGIN_FAILS) {
                    rec.lockedUntil = Date.now() + LOCKOUT_MS;
                    rec.count = 0;
                }
                loginFailures.set(key, rec);
                audit('login.fail', { ip: key, username: body.username ?? null });
                // Deliberately vague: do not reveal whether the user exists.
                return send(res, 401, { error: 'invalid credentials' });
            }

            loginFailures.delete(key);
            const { id, session } = createSession(user.username);
            audit('login.ok', { ip: key, username: user.username });

            return send(res, 200, { ok: true, csrf: session.csrf, user: user.username }, {
                'Set-Cookie': `sid=${encodeURIComponent(signSession(id))}; HttpOnly; SameSite=Strict; Path=/; Max-Age=${SESSION_TTL_MS / 1000}`,
            });
        }

        if (req.method === 'POST' && route === '/api/logout') {
            const found = getSession(req);
            if (found) {
                sessions.delete(found.id);
                audit('logout', { username: found.session.user });
            }
            return send(res, 200, { ok: true }, {
                'Set-Cookie': 'sid=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0',
            });
        }

        if (req.method === 'GET' && route === '/api/session') {
            const found = getSession(req);
            if (!found) return send(res, 401, { authenticated: false });
            return send(res, 200, {
                authenticated: true,
                user: found.session.user,
                csrf: found.session.csrf,
                lockControllable: LOCK_ENABLED,
            });
        }

        // --- state ----------------------------------------------------------
        if (req.method === 'GET' && route === '/api/state') {
            if (!requireSession(req, res)) return;
            return send(res, 200, buildSnapshot());
        }

        // --- SSE stream ------------------------------------------------------
        if (req.method === 'GET' && route === '/api/events') {
            if (!requireSession(req, res)) return;
            res.writeHead(200, {
                'Content-Type': 'text/event-stream',
                'Cache-Control': 'no-store',
                Connection: 'keep-alive',
                'X-Accel-Buffering': 'no',
            });
            res.write(`event: snapshot\ndata: ${JSON.stringify(buildSnapshot())}\n\n`);
            sseClients.add(res);

            // Keep intermediaries from timing the stream out.
            const ping = setInterval(() => {
                try { res.write(': ping\n\n'); } catch { /* closed */ }
            }, 25_000);

            req.on('close', () => {
                clearInterval(ping);
                sseClients.delete(res);
            });
            return;
        }

        // --- generic device command (NOT the lock) ---------------------------
        if (req.method === 'POST' && route === '/api/command') {
            const found = requireSession(req, res);
            if (!found) return;
            if (!requireCsrf(req, res, found.session)) return;

            const body = await readJson(req);
            const { device, payload } = body;
            if (typeof device !== 'string' || !device) {
                return send(res, 400, { error: 'device required' });
            }

            // Refuse to route lock operations through the unguarded endpoint.
            if (config.lock?.commandTopic
                && `zigbee2mqtt/${device}/set` === config.lock.commandTopic) {
                return send(res, 403, { error: 'use /api/lock for lock operations' });
            }

            const topic = `zigbee2mqtt/${device}/set`;
            const out = typeof payload === 'string' ? payload : JSON.stringify(payload ?? {});
            client.publish(topic, out);
            audit('command', { username: found.session.user, topic, payload: out });
            return send(res, 200, { ok: true });
        }

        // --- lock ------------------------------------------------------------
        if (req.method === 'POST' && route === '/api/lock') {
            const found = requireSession(req, res);
            if (!found) return;
            if (!requireCsrf(req, res, found.session)) return;

            const { session } = found;

            if (!LOCK_ENABLED) {
                return send(res, 403, { error: 'lock control is not configured' });
            }

            if (session.lockedUntil > Date.now()) {
                const secs = Math.ceil((session.lockedUntil - Date.now()) / 1000);
                audit('lock.lockout', { username: session.user });
                return send(res, 429, { error: `too many PIN attempts, retry in ${secs}s` });
            }

            const body = await readJson(req);
            const action = body.action;
            if (action !== 'lock' && action !== 'unlock') {
                return send(res, 400, { error: 'action must be lock or unlock' });
            }

            // The PIN is required per operation. A valid session is explicitly
            // not enough: being on the tailnet with an unlocked phone would
            // otherwise be a door-open button.
            const pinFresh = session.pinOkUntil > Date.now();
            if (!pinFresh) {
                if (typeof body.pin !== 'string'
                    || !verifySecret(body.pin, config.lockPin.salt, config.lockPin.hash)) {
                    session.pinFails += 1;
                    if (session.pinFails >= MAX_PIN_FAILS) {
                        session.lockedUntil = Date.now() + LOCKOUT_MS;
                        session.pinFails = 0;
                    }
                    audit('lock.pin_fail', { username: session.user, action });
                    return send(res, 401, { error: 'incorrect PIN' });
                }
                session.pinFails = 0;
                session.pinOkUntil = Date.now() + PIN_WINDOW_MS;
            }

            const payload = action === 'lock'
                ? (config.lock.lockPayload ?? 'true')
                : (config.lock.unlockPayload ?? 'false');

            client.publish(config.lock.commandTopic, String(payload));
            audit('lock.command', {
                username: session.user,
                action,
                topic: config.lock.commandTopic,
                payload: String(payload),
            });

            return send(res, 200, { ok: true, action });
        }

        // --- health (unauthenticated, deliberately minimal) -------------------
        if (req.method === 'GET' && route === '/api/health') {
            return send(res, 200, { ok: true, broker: state.connected });
        }

        return send(res, 404, { error: 'not found' });
    } catch (err) {
        console.error(`Request error on ${route}: ${err.message}`);
        return send(res, 400, { error: 'bad request' });
    }
});

const port = config.port || 8099;
const host = config.bindHost || '127.0.0.1';

server.listen(port, host, () => {
    console.log(`Dashboard listening on http://${host}:${port}`);
    if (host !== '127.0.0.1' && host !== 'localhost') {
        console.warn('');
        console.warn(`WARNING: bound to ${host}, not loopback.`);
        console.warn('The intended deployment binds loopback and exposes via `tailscale serve`,');
        console.warn('which supplies TLS and keeps this off your LAN entirely.');
    }
    console.log(`Lock control: ${LOCK_ENABLED ? 'ENABLED (PIN required per operation)' : 'disabled'}`);
});

for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => {
        console.log(`\n${sig} received, shutting down.`);
        client.end(true);
        server.close(() => process.exit(0));
        setTimeout(() => process.exit(0), 3000).unref();
    });
}
