# Troubleshooting

Symptom → likely cause. Ordered roughly by how often each comes up.

## Zigbee2MQTT

**Won't start: cannot open the serial port**

Something else holds it. In order of likelihood: a previous Zigbee2MQTT
instance still running, Z-Wave JS pointed at the same COM port, or a serial
terminal left open. On a dual-radio stick such as the HUSBZB-1 the two ports
are easy to transpose.

```powershell
Get-ScheduledTask -TaskName Zigbee2MQTT | Stop-ScheduledTask
Get-Process node -ErrorAction SilentlyContinue
.\scripts\Find-Coordinators.ps1
```

**Won't start: adapter did not respond**

Wrong `adapter` value, wrong baud rate, or a coordinator needing hardware flow
control. The valid `adapter` values are `deconz`, `zstack`, `zigate`, `ezsp`,
`ember`, `zboss`, `zoh`. Try removing the `adapter` line entirely first —
autodetection is usually right, and a *wrong* explicit value fails harder than
no value. If the adapter is EmberZNet/EZSP and still silent, try
`rtscts: true`.

**Custom converter has no effect**

`enable_external_js` is false. This is the default from 2.11.0 onward and it
fails *silently* — the file is ignored with nothing in the log pointing at the
cause. Confirm in `data\configuration.yaml`:

```yaml
advanced:
  enable_external_js: true
```

Then: converters must be `.mjs` using `export default`, and must live in
`data\external_converters\` — alongside `configuration.yaml`, not next to it in
the repository.

**Converter loads but the device is still unsupported**

The `zigbeeModel` string does not match exactly. It is case-sensitive and some
of this hardware emits trailing whitespace in its modelID.
`Get-DeviceFingerprint.ps1` flags that specifically. Copy the value from there
rather than retyping it.

**Battery never reports**

The device reports voltage, not percentage, and there is no conversion curve.
Add to the definition:

```js
meta: {battery: {voltageToPercentage: '3V_2100'}},
```

**Battery reads about half of reality**

The device reports `batteryPercentageRemaining` as 0–100 where ZCL specifies
0–200, so Zigbee2MQTT halves it. Use `dontDividePercentage` instead of a
voltage curve:

```js
meta: {battery: {dontDividePercentage: true}},
```

**`configure` fails with a timeout**

Normal for battery devices — they were asleep. Wake the device and hit
*Reconfigure*. If it fails while demonstrably awake, the definition binds a
cluster the device does not implement; drop it from `reporting.bind()` to match
the fingerprint dump.

**Device joins, then goes unavailable hours later**

Range or routing. Sleepy end devices do not route for each other, so a network
of nothing but battery sensors has no mesh. Add a mains-powered Zigbee device
between the coordinator and the dead zone. Also worth checking the Zigbee
channel against your Wi-Fi channel — the 2.4 GHz bands overlap badly.

**Rebuilds on every start**

Git is not on PATH for the account running the service. Zigbee2MQTT runs
`git rev-parse` to decide whether `dist/` is current; without Git it cannot
tell and rebuilds unconditionally.

## Mosquitto

**Clients rejected with "not authorised"**

`per_listener_settings true` means `password_file` and `allow_anonymous` must
appear *inside* each listener block. A `password_file` at global scope is
ignored under that setting, and every client is rejected.

**Service will not start**

Check `C:\ProgramData\xfinity-home\mosquitto\mosquitto.log`. Then run it in the
foreground, which prints the parse error the service swallows:

```powershell
& 'C:\Program Files\mosquitto\mosquitto.exe' `
    -c 'C:\ProgramData\xfinity-home\mosquitto\mosquitto.conf' -v
```

**Dashboards come up blank after a restart**

Retained state was lost. Confirm `persistence true` and that the service
account can write to `persistence_location`. Without it, every retained device
state is gone on restart and a battery contact sensor may not report again for
hours.

**Browser client cannot connect**

Browsers cannot speak raw MQTT over TCP. Use the WebSockets listener on 9001,
not 1883.

## Z-Wave

**Lock pairs but ignores every command**

It was included without security keys present. There is no way to add security
to an existing association. Exclude it, confirm the keys are saved and Z-Wave
JS UI has been restarted, then re-include with S2. Check the node's granted
security class afterwards — "None" means it happened again.

**Inclusion fails at the door**

S2 inclusion is chatty and locks have poor RF. Include near the controller,
then re-site and heal the network.

**Lock state does not update when operated by hand**

Association group 1 is not set to the controller, so the lock never reports
unsolicited changes. Set it in the node's association settings. Polling is a
workaround, not a fix — it drains the batteries.

## Cameras

**Every probed path returns 401**

Credentials, not paths. The camera's RTSP account is sometimes distinct from
its web UI account.

**Every probed path times out but port 554 is open**

Something answers on 554 but not RTSP, or the firmware exposes RTSP only after
an explicit enable. If the camera's own web UI shows a stream URL, use it.
Otherwise try ONVIF discovery, which reports the RTSP URI directly.

**Stream connects then stalls after a few seconds**

RTP over UDP. Force TCP:

```yaml
front_door: ffmpeg:rtsp://admin:PASSWORD@192.168.1.50:554/img/media.sav#input=rtsp/tcp
```

**Camera starts refusing connections**

Too many direct clients. These cameras have a low connection limit. Point every
consumer at go2rtc's republished stream on `rtsp://127.0.0.1:8554/<name>`
instead of at the camera.

## General

**A service does not come back after reboot**

```powershell
Get-ScheduledTask -TaskName Zigbee2MQTT, ZWaveJSUI, go2rtc |
    Select-Object TaskName, State
Get-ScheduledTaskInfo -TaskName Zigbee2MQTT
```

`LastTaskResult` of 0 means the last run exited cleanly. Tasks run as SYSTEM,
which has a different PATH and different profile directories than your user —
a script that works interactively and fails as a task is usually resolving a
relative path or a user-scoped environment variable.

**Everything works until the host sleeps**

USB selective suspend powers down the coordinators and they do not always come
back. Disable it for the USB root hubs in Device Manager, and set the machine's
power plan to never sleep. A control plane that holds a door lock should not
be on a sleeping host.
