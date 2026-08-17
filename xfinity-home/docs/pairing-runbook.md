# Pairing runbook

Procedure per device class. Read the Zigbee section before pairing anything —
the channel decision is irreversible without a full re-pair.

## Before the first device

1. Mosquitto is running and verified (`02-Setup-Mosquitto.ps1` ends with a
   round-trip check).
2. Zigbee2MQTT starts cleanly in the foreground and logs a coordinator firmware
   version.
3. The Zigbee channel is settled. **Changing it later re-pairs everything.**
4. For anything Z-Wave: the four security keys are saved in Z-Wave JS UI and it
   has been restarted since.

Pair **one device at a time**. Batching makes it impossible to tell which
device produced which log line, and these sensors join slowly enough that two
overlapping joins routinely get attributed to the wrong node.

## Zigbee sensors

Applies to Sercomm, Visonic, Centralite and Leedarson contact, motion, water
and glass-break sensors.

1. **Open permit-join deliberately.** Zigbee2MQTT frontend → *Permit join*,
   scoped to a short window. Do not leave it open between devices; an open
   network is how unknown devices end up joined.

2. **Factory reset the device.** Mechanism varies — usually a tamper switch
   held while inserting the battery, or a reset pin. The device must be in
   join mode, not merely powered.

3. **Watch the log.** A successful join produces an interview, then either a
   resolved definition or an "unsupported" line naming the modelID.

4. **Wake it for `configure`.** Battery sensors sleep, and `configure` — which
   binds clusters and sets up attribute reporting — can only run while awake.
   Trigger the device (open/close the contact, trip the PIR, press tamper) and
   then use *Reconfigure* in the frontend. A first-attempt timeout is normal.

5. **Verify real telemetry** before mounting anything:

   ```powershell
   & 'C:\Program Files\mosquitto\mosquitto_sub.exe' `
       -h 127.0.0.1 -u homeauto -P <password> -t 'zigbee2mqtt/#' -v
   ```

   Trip the sensor. You want the state change *and* a plausible battery value.
   A battery reading of `null`, or ~50% on a fresh cell, means the converter
   needs a battery quirk — see
   [`../external_converters/README.md`](../external_converters/README.md).

6. **Rename it** to something meaningful before pairing the next one.
   `0x00158d0001abcdef` is unusable six devices later.

### If the device joins as unsupported

```powershell
.\scripts\Get-DeviceFingerprint.ps1
```

That prints the real modelID, manufacturer and cluster map, plus a converter
skeleton pre-filled with those values. Drop it in `external_converters\`,
restart Zigbee2MQTT, wake the device, Reconfigure.

### If the device will not join at all

Distance first: pair within a few metres of the coordinator, then move it. A
sensor that joins nearby and drops out on the wall is a routing problem, not a
pairing problem, and is solved by adding a mains-powered Zigbee router between
them — not by re-pairing.

## Z-Wave lock (Kwikset Convert 914C)

**Confirm the security keys are saved and Z-Wave JS UI has been restarted.**
A lock included without keys pairs, looks healthy, and then rejects every
command. Recoverable only by excluding and re-including.

1. **Exclude first, always.** Even a factory-new lock. Z-Wave JS UI →
   *Manage nodes* → *Exclude*, then run the lock's exclusion sequence. This
   clears any stale association from the previous controller — and this lock
   has one, since it was on an Xfinity controller.

2. **Include with S2.** *Manage nodes* → *Include* → **Secure (S2)**. Enter the
   5-digit PIN from the lock's DSK label when prompted. If S2 is not offered,
   the lock is 500-series and will negotiate S0 — acceptable for a lock, and
   still encrypted.

3. **Pair it in place, or near the controller?** Locks are awkward: they are
   battery devices with poor RF, but S2 inclusion is chatty. If inclusion fails
   at the door, include it near the controller and then re-site it — the
   network heals routes on its own, and you can force it with a network heal.

4. **Confirm the granted security class.** The node detail page names it. If it
   says "None" or "Unsecured", stop — exclude and redo. Do not proceed hoping
   it works; it will not.

5. **Test both directions.** Lock and unlock from the UI, then manually operate
   the deadbolt and confirm the state change appears. One-way operation usually
   means association group 1 is not set to the controller.

6. **Verify over MQTT** with prefix `zwave`:

   ```powershell
   & 'C:\Program Files\mosquitto\mosquitto_sub.exe' `
       -h 127.0.0.1 -u homeauto -P <password> -t 'zwave/#' -v
   ```

## Cameras (Sercomm XCam)

1. **Give each camera a static lease** on the router, keyed to its MAC. RTSP
   URLs embed the IP; a DHCP change silently breaks every stream.

2. **Find the RTSP path.** It is undocumented and varies by firmware:

   ```powershell
   .\scripts\05-Setup-Cameras.ps1 -Probe -CameraIp 192.168.1.50 `
       -CameraUser admin -CameraPassword <pw>
   ```

   Auth rejections on *every* path mean wrong credentials, not wrong paths.
   Timeouts on every path usually mean RTSP is not enabled on the firmware.

3. **Add the stream** to `C:\ProgramData\xfinity-home\go2rtc\go2rtc.yaml`,
   restart go2rtc, confirm the preview at http://127.0.0.1:1984.

4. **Consume from go2rtc, never from the camera.** These cameras have a low
   connection limit and start refusing connections when several clients attach
   directly. go2rtc connects once and fans out.

## After everything is paired

- Back up `C:\ProgramData\xfinity-home\zwave-keys.json` off the machine.
- Back up `C:\zigbee2mqtt\data\` — it holds the network key and device
  database. Without it a coordinator failure means re-pairing every device.
- Confirm all four services survive a reboot.
- Close permit-join and leave it closed.
