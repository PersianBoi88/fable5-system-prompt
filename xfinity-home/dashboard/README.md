# Mobile dashboard

A phone-accessible view of the whole control plane — sensors, lock, cameras —
reachable over Tailscale with real TLS, and able to operate the deadbolt behind
a separate PIN.

## Why there is a backend at all

The obvious design is a static page talking straight to Mosquitto over the
WebSockets listener on port 9001. That works, and for a read-only dashboard it
would be the right answer.

It stops being the right answer the moment the dashboard can open a door. A
browser-side MQTT client has to carry credentials that can *publish*, and
anyone who loads the page has them. So instead: the browser talks to this
server, and only this server talks to the broker. A stolen phone session cannot
be replayed against the broker directly.

## Security model

The threat this is actually designed around is **an unlocked phone in the wrong
hands** — not a network attacker. Tailscale already handles the network. But
your phone is authenticated to the tailnet the moment it is unlocked, so
network-level access cannot be what gates the door.

| Layer | Mechanism |
|---|---|
| Network | Loopback bind + `tailscale serve`. Nothing on the LAN or the internet. |
| Login | scrypt (64-byte output, random 16-byte salt), timing-safe compare |
| Session | HMAC-SHA256 signed cookie, `HttpOnly`, `SameSite=Strict`, 12h TTL |
| CSRF | Per-session token required in `X-CSRF-Token` on every mutation |
| Lock | **Separate PIN, re-entered per operation**, valid 30s |
| Brute force | 5 attempts then a 15-minute lockout, on both login and PIN |
| Audit | Every login, command and lock operation appended as JSON lines |
| Content | CSP forbids all external origins; no CDN, no fonts, no analytics |

Login failures are deliberately vague about whether the username exists, and
the audit log records the *fact* of an attempt without ever recording the
secret.

## Dependencies

One: `mqtt`. Sessions, hashing, CSRF and the event stream all use Node
built-ins. Server-Sent Events are used instead of WebSockets specifically so
that `ws` isn't needed — state push is one-directional anyway. This is a
process that can unlock a front door; the dependency tree is part of its attack
surface.

## Files

```
dashboard/
├── server.js              backend: MQTT bridge, auth, SSE, lock gating
├── public/index.html      the entire frontend, one self-contained file
├── config.example.json    annotated reference (real config lives in ProgramData)
└── package.json
```

Runtime config: `C:\ProgramData\xfinity-home\dashboard.json`
Audit log: `C:\ProgramData\xfinity-home\dashboard-audit.log`

## Setup

```powershell
.\scripts\06-Setup-Dashboard.ps1      # deps, account, PIN, config, startup task
.\scripts\Get-ZWaveTopics.ps1 -Seconds 30   # discover the lock's real topics
.\scripts\07-Setup-RemoteAccess.ps1   # Tailscale + HTTPS
```

The lock topics are **not** set by the installer. Z-Wave JS UI's topic layout
depends on your node names and topic mode, so it has to be observed rather than
assumed — `Get-ZWaveTopics.ps1` captures it and emits the JSON block to paste
in.

## Before trusting the unlock button

Confirm the lock tile tracks the physical deadbolt in both directions. Turn the
bolt by hand and watch the tile follow it. A state topic that reads backwards
is worse than no state at all — it will confidently tell you the house is
locked while it stands open.

Also worth doing once: check the audit log actually recorded your test
operations. If it didn't, something is wrong with the deployment, and an
unlogged door is not one you want to be operating remotely.

## Testing done

The backend's security boundaries were exercised directly against a running
instance:

- unauthenticated access to state, events and lock all refused (401)
- wrong password, unknown user both refused, without distinguishing between them
- session cookie issued `HttpOnly`
- lock refused without a CSRF token (403)
- lock refused with no PIN, and with a wrong PIN (401)
- lock accepted with the correct PIN (200)
- five wrong PINs triggered the lockout (429)
- audit log recorded every event, and contained neither the password nor the PIN
- SSE delivered a snapshot on connect and pushed status changes
- the server stayed up when the broker was unreachable, and reconnected

The frontend has not been exercised in a real browser — there isn't one in the
build environment.
