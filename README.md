# Yaapu telemetry for CogniPilot Cerebri

Flight telemetry on the radio: attitude, flight mode, GPS, battery and status
messages, drawn on the transmitter screen while you fly.

The flight controller runs CogniPilot Cerebri and sends Yaapu passthrough
telemetry over CRSF. The radio runs EdgeTX 2.11 or newer with these Lua
scripts. CRSF is the only supported link, over an ELRS (or other Crossfire)
module. The FrSky S.Port path of the original project has been removed.

## Supported radios

| Radio             | Screen  | Copy to the SD card                               |
| ----------------- | ------- | ------------------------------------------------- |
| RadioMaster TX15  | 480x320 | `OTX_ETX/c480x320/SD` + `OTX_ETX/color_common/SD` |
| RadioMaster Boxer | 128x64  | `OTX_ETX/bw128x64/SD` + `OTX_ETX/bw_common/SD`    |
| RadioMaster GX12  | 128x64  | `OTX_ETX/bw128x64/SD` + `OTX_ETX/bw_common/SD`    |

## Requirements

- EdgeTX 2.11.2 or newer on the radio (2.11.2 added the CRSF RPM sensors).
- ExpressLRS 3.5.5 or newer on both the TX module and the receiver (older
  receivers do not forward the RPM frame).
- Cerebri built with `CONFIG_RDD2_CRSF_TELEMETRY=y`, its receiver bound.

## Install on a radio (TX15)

1. **Copy the scripts.** Connect the radio over USB, pick *USB storage (SD)*
   on the radio, copy the *contents* of `OTX_ETX/c480x320/SD` to the root of
   the card, then the contents of `OTX_ETX/color_common/SD`. `WIDGETS/` and
   `IMAGES/` end up next to the folders already on the card; existing files
   are replaced. Eject and unplug.
2. **Set the module to CRSF.** On the model, *Model setup*, external module
   type *CRSF*, baud rate 400000 (the default).
3. **Set the ELRS link to 500 Hz and 1:4.** *Tools*, *ExpressLRS*: *Packet
   Rate* `500Hz`, *Telem Ratio* `1:4`, then leave the script. The firmware
   paces its telemetry for exactly this setting (see the budget below); at
   1:8 or slower the widget lags and drops frames.
4. **Discover the sensors.** Power the flight controller, wait for the link,
   open the model's *Telemetry* page and run *Discover new sensors* until the
   list is stable (see the next section). `FM`, `GPS`, `Sats`, `RxBt`, `RFMD`
   and four `RPM` entries must be there.
5. **Add the widget.** *Screens*, add a screen of type *Widgets*, full
   screen layout, widget `yaapu`. For the map, add a second screen with
   another `yaapu` widget and set its *Screen Type* to 5.
6. **Run Yaapu Config once.** *Tools*, *Yaapu Config*: set *enable RPM
   support* to `rpm1+rpm2` for the motor bars, *enable battery % by voltage*
   if wanted, and press *Enter* on an edited value so the configuration file
   is written for this model. A long press on *Menu* over the widget reopens
   it later.

Check: the horizon follows the board when it is tilted, the mode line reads
the flight mode with `DISARMED` until the vehicle arms, the satellite count
and voltage match the board's console, and the M1 to M4 bars follow the
motors.

## Discover the CRSF telemetry sensors

EdgeTX turns the CRSF frames from the receiver into telemetry sensors, and the
widget reads several of them directly rather than decoding every frame itself:
`FM` for the flight mode name and the armed state, `GPS` for the position that
centres the map, `Sats`, `RxBt` and `Curr` for the native battery and GPS
values, and `RFMD` for the link mode. EdgeTX only creates a sensor when it has
been discovered, so with an undiscovered sensor the mode line stays blank, the
map page stays black and the arm state never changes, even though the frames
arrive.

Discovery also creates the mechanical RPM of the four motors. EdgeTX names all
four sensors `RPM` and tells them apart by their instance, so the telemetry page
lists `RPM` four times. Set *enable RPM support* to `rpm1+rpm2` in *Yaapu
Config* and the TX15 widget draws them as four bars labelled M1 to M4 below the
HUD.

Run *Discover new sensors* on the model's *Telemetry* page with the flight
controller powered, the receiver bound and, for `GPS`, a fix or at least a few
seconds of GPS frames. Stop the discovery once the list is stable. Repeat it
after a firmware update that adds frames, after re-binding a new receiver, and
on every model that uses the widget, because sensors are stored per model.

## Install on a radio (Boxer, GX12)

Same steps, but copy the contents of `OTX_ETX/bw128x64/SD` and
`OTX_ETX/bw_common/SD` to the card root. Set the module, the 500 Hz 1:4 link and the sensors up as
above, then open the model's *Telemetry* page, scroll to *Screen 1*, set it to
*Script* and pick `yaapu7`. Run *Yaapu Config* from *Tools* once.

## ELRS link settings and telemetry budget

The firmware paces its telemetry for ELRS 2.4 GHz at a **500 Hz packet rate
with a 1:4 telemetry ratio**. Set both in the ELRS Lua script on the radio
(`Tools`, then `ExpressLRS`). At that setting the receiver sends 125 telemetry
packets per second, which ELRS rates at 4687 bit/s, about 585 bytes/s of CRSF
frames, and the same channel carries the receiver's link statistics.

The receiver queues telemetry in a 512 byte FIFO. GPS, battery and flight
mode frames overwrite the older queued frame of their type, but the Yaapu
passthrough frames are appended, so the firmware keeps them well below the
link's drain rate; otherwise the status word waits seconds behind queued
attitude frames. Measured with the mirror tool (`tools/crsf_mirror.py`): a 1:8
link delivers about 8 passthrough frames per second in total and drops the
rest, a 1:4 link keeps up with the defaults below, roughly 310 bytes/s:

| Frame                              | Rate    | Bytes/s |
| ---------------------------------- | ------- | ------- |
| Attitude and heading (passthrough) | 10 Hz   | 180     |
| GPS position                       | 1 Hz    | 19      |
| Status, GPS status, home           | 1 Hz    | 24      |
| Flight mode name (`FM`)            | 0.5 Hz plus every mode change | 7 |
| Battery (CRSF and passthrough)     | 0.33 Hz | 8       |
| Frame type parameter               | 0.25 Hz | 3       |
| Motor RPM (CRSF RPM frame, 4 motors) | 4 Hz  | 68      |

Status texts (ready, armed, disarmed, failsafe), every flight mode change and
every armed or failsafe change are sent the moment they happen, ahead of the
scheduled frames. The armed state itself rides the flight mode frame (a
trailing `*` on the mode name means disarmed), which the receiver never queues,
so the widget's ARMED/DISARMED follows the switch even when the passthrough
queue is busy. The two fastest periods are Kconfig options
(`CONFIG_RDD2_CRSF_TELEMETRY_ATTITUDE_PERIOD_MS` and
`CONFIG_RDD2_CRSF_TELEMETRY_STATUS_PERIOD_MS`): on a 1:8 link set the attitude
period to 170 ms, on 1:16 to 500 ms; the receiver drops passthrough frames it
cannot fit rather than delaying them forever.

## Map page

The widget's pages are chosen with its "Screen Type" option: 1 is the HUD,
2 the message history, 5 the satellite map (6 plot, 7 and 8 statistics). Put a
second `yaapu` widget on another screen with Screen Type 5, or use the page
toggle in Yaapu Config. The widget defaults to map provider `Google`, map type
`GoogleSatelliteMap`, zoom 16 (12 to 18), which matches the shipped tiles; the
wheel zooms in and out on the map page while it is full screen; a
change in Yaapu Config is only written when the edited value is confirmed with
ENTER. The map centres on the aircraft's GPS position from the `GPS` telemetry
sensor, so the sensors must have been discovered (see above), and it draws
once there is a fix.

The shipped tiles cover an 8 km radius around Lafayette, Indiana at zoom 12
to 17, and a 3 km radius at zoom 18. Tiles for another area are one command,
then copy `OTX_ETX/color_common/SD/IMAGES` to the card again:

```
tools/make_map_tiles.py LAT LON RADIUS_KM
```

The script's default zoom range is the widget's, 12 to 18. Zoom 18 is the
expensive level (about 20000 tiles and 110 MB for an 8 km radius), so for a
large radius run it once for the whole area and once more with a small radius
and `--zooms 18-18`.

## Firmware side

The flight controller needs a Cerebri RDD2 build with
`CONFIG_RDD2_CRSF_TELEMETRY` enabled, wired to the ELRS receiver over CRSF.

## Testing

`tests/check.sh` compiles every script and runs them on the host against CRSF
frames captured from the firmware encoder. See `tests/README.md`.

## Credits

A fork of [yaapu/FrskyTelemetryScript](https://github.com/yaapu/FrskyTelemetryScript)
by Alessandro Apostoli, reduced to CRSF passthrough on the radios listed above.
The [project wiki](https://github.com/yaapu/FrskyTelemetryScript/wiki) covers the
screens and the configuration options in detail. Licensed under the GNU General
Public License v3, see `LICENSE`.
