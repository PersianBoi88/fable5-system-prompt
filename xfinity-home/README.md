# Local smart home control plane for reclaimed Xfinity Home hardware

A cloud-free, MQTT-based control plane for ex-Xfinity Zigbee sensors, a Z-Wave
smart lock and Sercomm IP cameras, running natively on Windows.

## What this is, and what it is not

This is a **deployment kit**, not a running system. It was authored in a Linux
container with no access to the Windows host, its USB ports or its device
network — so nothing here has been executed against real hardware. Every
script is written to be run by you, on the target machine, in order.

That constraint shaped the design in a way that is worth knowing about:
because nothing could be verified interactively, the scripts verify
*themselves*. `02-Setup-Mosquitto.ps1` proves the broker with a real
authenticated publish/subscribe round trip and then checks that anonymous
access is refused. `03-Setup-Zigbee2MQTT.ps1` fails loudly if template
substitution leaves a token behind. `Find-Coordinators.ps1` refuses to guess
between two identical-looking USB bridges. Where something genuinely cannot be
known ahead of time — your COM ports, your camera's RTSP path, the exact ZCL
model IDs your sensors report — there is a tool that discovers it rather than a
value hardcoded on a guess.

Everything below was checked against Zigbee2MQTT 2.13.0 sources rather than
recalled: the settings schema, the external converter format, the device
definitions your hardware may already match.

## Architecture

```
   Zigbee radio                Z-Wave radio               IP cameras
   (USB coordinator)           (USB coordinator)          (Sercomm XCam)
        │                            │                          │
        │ serial                     │ serial                   │ RTSP
        ▼                            ▼                          ▼
   Zigbee2MQTT                  Z-Wave JS UI                 go2rtc
   (Node, from source)          (standalone exe)         (standalone exe)
        │                            │                          │
        └────────────┬───────────────┘                          │
                     ▼                                          │
              Mosquitto broker                                  │
              127.0.0.1:1883 (auth)                             │
              127.0.0.1:9001 (websockets)                       │
                     │                                          │
                     └──────────────┬───────────────────────────┘
                                    ▼
                           dashboard backend
                           127.0.0.1:8099  (loopback only)
                                    │
                                    ▼
                            tailscale serve
                          https://<host>.ts.net
                                    │
                                    ▼
                                  phone
```

Note where the trust boundary sits: the dashboard binds loopback and is
published to your tailnet by `tailscale serve`, which also supplies TLS.
Nothing listens on your LAN, and nothing is port-forwarded.

Nothing in this stack talks to a vendor cloud. The broker is the only
integration point, so a dashboard subscribes in one place rather than speaking
three protocols.

## Order of operations

Run each from an **elevated PowerShell** session, in this order.

| # | Script | What it does |
|---|---|---|
| 0 | `Find-Coordinators.ps1` | Identify which COM port is which radio |
| 1 | `01-Install-Prereqs.ps1` | Node 22 LTS, Git, corepack/pnpm |
| 2 | `02-Setup-Mosquitto.ps1` | Broker, credentials, service, firewall, verify |
| 3 | `03-Setup-Zigbee2MQTT.ps1` | Clone, build, configure, startup task |
| 4 | `04-Setup-ZWaveJS.ps1` | Z-Wave JS UI + **security keys for the lock** |
| 5 | `05-Setup-Cameras.ps1` | go2rtc + RTSP path discovery |
| 6 | `06-Setup-Dashboard.ps1` | Mobile dashboard: account, lock PIN, startup task |
| 7 | `07-Setup-RemoteAccess.ps1` | Tailscale + HTTPS, for phone access |

Four helpers, used as needed rather than in sequence:

| Script | What it does |
|---|---|
| `Find-Coordinators.ps1 -Watch` | Definitively map a stick to a COM port by unplugging it |
| `Get-DeviceFingerprint.ps1` | Dump a device's ZCL fingerprint and generate a converter skeleton |
| `Get-ZWaveTopics.ps1` | Observe the Z-Wave topic tree and find the lock's real topics |
| `Test-Stack.ps1` | End-to-end health check across all four services |
| `Backup-Config.ps1` | Archive the state whose loss means re-pairing everything |

`Test-Stack.ps1` checks live state over MQTT rather than just whether processes
exist — a Zigbee2MQTT task sitting in "Running" with its coordinator unplugged
is not a healthy stack. It exits non-zero on failure, so it works as a smoke
test. Run it after setup and whenever something feels wrong.

### Start here

```powershell
cd xfinity-home\scripts
.\Find-Coordinators.ps1
```

That tells you what the machine can see before anything is installed. If it
cannot tell your two sticks apart — likely, since several Zigbee and Z-Wave
coordinators share the same Silicon Labs CP210x bridge chip and therefore the
same USB VID/PID — use `-Watch`, which identifies a stick by noticing which
port disappears when you unplug it.

## Things that will bite, in the order they will bite you

**External converters are disabled by default.** Zigbee2MQTT 2.11.0 and later
ship with `enable_external_js: false`. Custom device handlers are then ignored
*silently* — no error, no log line naming the cause, devices just stay
unsupported. The generated config sets it to `true`.

**Check before you write a converter.** A good share of this fleet is already
supported upstream — the Xfinity `XHS2-SE` contact sensor, Visonic `MCT-340 E`,
Sercomm `SZ-PIR02`/`SZ-PIR04N`, Centralite `3323-G`/`3328-G`/`3400-D`,
SmartThings `3300-S`. Pair first; only devices Zigbee2MQTT logs as unsupported
need work. See [`external_converters/README.md`](external_converters/README.md).

**The Zigbee channel is a one-time free choice.** Changing it later forces a
re-pair of every device. Since the whole fleet is being factory reset anyway,
pick it now — the default here is 25, which sits clear of the busiest 2.4 GHz
Wi-Fi range. Check it against your own Wi-Fi channel before committing.

**Configure the Z-Wave security keys before including the lock.** This is the
one genuinely unrecoverable ordering mistake in the whole build. A Z-Wave lock
included without security keys present will pair, appear healthy, report itself
as a lock — and then reject every lock/unlock command. There is no way to add
security to an existing association; the fix is a full exclude and re-include.
`04-Setup-ZWaveJS.ps1` generates the four keys and prints them before it ever
mentions inclusion.

**One process per serial port.** If Zigbee2MQTT and Z-Wave JS are pointed at
the same COM port, the second to start fails to open it. Worth remembering with
a dual-radio stick like the HUSBZB-1, which presents two ports from one dongle.

**Sleepy devices fail `configure` on the first try.** Battery sensors are
asleep when Zigbee2MQTT tries to bind clusters. Expected. Wake the device and
use Reconfigure. Do not paper over it with a `try/catch` — that converts a
retryable timeout into a device that pairs but never reports.

## Where things live

```
xfinity-home/
├── scripts/                    numbered setup + two discovery helpers
├── config/
│   ├── mosquitto/              broker config (deployed to ProgramData)
│   ├── zigbee2mqtt/            configuration.yaml template
│   └── go2rtc/                 camera stream config template
├── external_converters/        ex-Xfinity device handlers (.mjs)
└── docs/
    ├── pairing-runbook.md      per-device-class pairing procedure
    └── troubleshooting.md      symptom → cause
```

Runtime state and secrets live outside the repository:

| Path | Contents |
|---|---|
| `C:\ProgramData\xfinity-home\credentials.json` | MQTT account (ACL: SYSTEM + Administrators) |
| `C:\ProgramData\xfinity-home\zwave-keys.json` | Z-Wave security keys (same ACL) |
| `C:\ProgramData\xfinity-home\mosquitto\` | Broker config, password file, persistence, log |
| `C:\zigbee2mqtt\` | Zigbee2MQTT checkout; config in `data\` |
| `C:\zwave-js-ui\` | Z-Wave JS UI |
| `C:\go2rtc\` | go2rtc |

Generated credentials never enter the repository.

## Backups

Two things in this stack are genuinely irreplaceable, and both mean physically
re-pairing every device in the house if lost:

- **`zwave-keys.json`** — the Z-Wave network security keys. Without them every
  secure device, the lock included, must be excluded and re-included.
- **`C:\zigbee2mqtt\data\`** — the Zigbee network key, device database and
  coordinator backup. Without them every sensor must be re-paired.

```powershell
.\scripts\Backup-Config.ps1              # hot copy
.\scripts\Backup-Config.ps1 -StopServices # quiesced, guaranteed consistent
```

The archive contains network keys, the MQTT password and any camera passwords
in cleartext. It is ACL-restricted on creation, but that does not survive a
copy to a USB stick or a cloud folder — anyone holding it can join your Z-Wave
network and operate the lock. Store it accordingly, and store it **off this
machine**: a disk failure is one of the two cases a backup protects against,
and a backup that only exists on the failed disk protects against neither.

## Services

All three run as scheduled tasks at startup under SYSTEM, which avoids taking a
dependency on NSSM or WinSW. Mosquitto runs as a real Windows service.

```powershell
Get-ScheduledTask -TaskName Zigbee2MQTT, ZWaveJSUI, go2rtc
Start-ScheduledTask -TaskName Zigbee2MQTT
Get-Service mosquitto
```

Zigbee2MQTT crash recovery uses its own `Z2M_WATCHDOG`, which restarts the
controller internally on a 1/5/15/30/60-minute backoff.

## Web interfaces

All bound to loopback. Reach them from another machine only after deciding you
want that.

| Service | URL | Auth |
|---|---|---|
| Dashboard | http://127.0.0.1:8099 | login + separate lock PIN |
| Zigbee2MQTT | http://127.0.0.1:8080 | token, printed at setup |
| Z-Wave JS UI | http://127.0.0.1:8091 | set on first run |
| go2rtc | http://127.0.0.1:1984 | none — keep it on loopback |

## Phone access

The dashboard ([`dashboard/`](dashboard/)) shows sensors, cameras and the lock,
and can operate the deadbolt. It reaches your phone over Tailscale at
`https://<machine>.ts.net`.

The security model is worth understanding, because the thing it defends against
is probably not what you'd assume. Tailscale already handles network access —
the real exposure is **an unlocked phone in someone else's hands**, which is
already authenticated to the tailnet. So network access deliberately is *not*
what gates the door: the lock requires a separate PIN, re-entered on every
operation, rate-limited to five attempts, and written to an audit log.

MQTT credentials never reach the browser. The phone talks to the dashboard
backend; only the backend talks to the broker.

One caveat on the no-cloud goal: Tailscale's coordination server is SaaS. It
brokers keys and cannot read your traffic — your telemetry never leaves the
house — but it is a third-party dependency. If that bothers you later,
[Headscale](https://github.com/juanfont/headscale) is a self-hosted control
server and nothing in the dashboard would change.

**Before trusting the unlock button:** turn the deadbolt by hand and confirm
the tile follows it in both directions. A state topic that reads backwards will
confidently report the house locked while it stands open.

## On the legality of the hardware side

Factory-resetting devices you own, running them on open-source software, and
declining to route your home's sensor data through an ISP is squarely within
what owning hardware means. Nothing in this repository circumvents access
controls, extracts vendor firmware or touches a service you do not have rights
to — it configures three widely-used open-source projects to talk to radios
over USB. The physical reset, PoE and firmware work described in the brief is
yours; this kit picks up at the point where a device is ready to join a
network you control.
