# External converters for ex-Xfinity Zigbee devices

## Read this before writing a converter

**Check whether the device is already supported first.** A meaningful share of
the ex-Xfinity fleet is already in `zigbee-herdsman-converters` upstream, and a
custom converter that shadows a working built-in definition is a net loss —
you inherit maintenance of something that was already handled.

Verified as supported upstream at the time of writing:

| Device | Upstream model | Vendor file |
|---|---|---|
| Xfinity door/window contact | `XHS2-SE` | `sercomm.ts` |
| Visonic door/window contact | `MCT-340 E`, `MCT-340 SMA` | `visonic.ts` |
| Sercomm PIR motion | `SZ-PIR02`, `SZ-PIR04N` | `sercomm.ts` |
| Sercomm water leak | `SZ-WTD03` | `sercomm.ts` |
| Centralite micro door sensor | `3323-G` | `centralite.ts` |
| Centralite micro motion | `3328-G` | `centralite.ts` |
| Centralite security keypad | `3400-D`, `3400` | `centralite.ts` |
| Contact sensor | `3300-S` | `smartthings.ts` |

So pair a device **before** assuming it needs work. Only devices that
Zigbee2MQTT logs as unsupported need anything here.

## Enabling external converters

Zigbee2MQTT **2.11.0 and later disable external JavaScript by default.** With
it off, the files in this directory are ignored silently — no error, no log
line pointing at the cause, devices just stay unsupported. The deployed
`configuration.yaml` sets:

```yaml
advanced:
  enable_external_js: true
```

This permits arbitrary user-supplied JavaScript to run inside the Zigbee2MQTT
process. Only put code here that you have read.

## Where these files live

Converters must sit in an `external_converters` folder **alongside**
`configuration.yaml` — that is, `<install>\data\external_converters\`.
`03-Setup-Zigbee2MQTT.ps1` copies them there. They are ES modules (`.mjs`) and
must `export default` a definition object, or an array of them.

## Workflow for an unsupported device

1. **Pair it.** Open permit-join in the frontend, factory-reset the device,
   wait for it to join. It will appear with a name like `0x00158d0001abcdef`
   and be flagged unsupported.

2. **Capture its fingerprint.** Run:

   ```powershell
   .\scripts\Get-DeviceFingerprint.ps1
   ```

   This dumps `modelID`, `manufacturerName`, and the endpoint/cluster map for
   every device Zigbee2MQTT does not recognise, and prints a converter
   skeleton pre-filled with the real values.

3. **Start from the closest template here**, paste in the real `modelID`, and
   adjust the cluster list to match what the fingerprint actually reported.

4. **Restart Zigbee2MQTT** and re-interview the device from the frontend
   (Device → Reconfigure).

## The two quirks that account for most ex-Xfinity battery weirdness

These devices were built for a controller that did its own normalisation, so
their ZCL power reporting is frequently off-spec in one of two ways.

**1. Voltage instead of percentage.** Many report only
`genPowerCfg.batteryVoltage` (attribute `0x0020`, decivolts) and never populate
`batteryPercentageRemaining`. Without a conversion curve the battery entity
stays empty forever. Fix — this is the same curve the upstream `XHS2-SE`
definition uses:

```js
meta: {battery: {voltageToPercentage: '3V_2100'}},
```

Only two named curves exist: `'3V_2100'` and `'3V_1500_2800'`. For anything
else, give an explicit linear range instead:

```js
meta: {battery: {voltageToPercentage: {min: 2500, max: 3200}}},
```

**2. Percentage on the wrong scale.** ZCL defines
`batteryPercentageRemaining` as 0–200 (half-percent units), so Zigbee2MQTT
divides by two. Some of this hardware reports a plain 0–100 instead, which
shows a device at 50% when it is actually full. Fix:

```js
meta: {battery: {dontDividePercentage: true}},
```

Diagnosing which: watch the reported value against a fresh cell. A brand-new
battery reading ~50% means you need `dontDividePercentage`. A battery entity
that never appears at all means you need `voltageToPercentage`.

## Tamper

Tamper is bit 2 of the IAS Zone `zoneStatus` bitmap and arrives on the same
message as the primary alarm. The `fz.ias_*_alarm_1` converters already decode
it; you only need to declare `e.tamper()` in `exposes` for it to surface. If
tamper never fires, confirm the device actually implements it — several of
these enclosures have a tamper spring that is only wired on the wall-mount
variant.

## Sleepy devices and `configure`

Battery-powered sensors sleep. The `configure` block binds clusters and sets up
attribute reporting, and it can only run while the device is awake, so it often
fails on the first attempt with a timeout. That is expected. Wake the device
(open/close the contact, trigger the PIR, or press the tamper switch) and use
**Reconfigure** in the frontend. Do not wrap `configure` in a `try/catch` to
make the error go away — it will hide genuine binding failures and leave you
with a device that pairs but never reports.
