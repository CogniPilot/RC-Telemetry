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

## Install on a radio (TX15)

1. Connect the radio to the computer with USB and pick "USB storage (SD)" on the
   radio, so the SD card appears as a drive.
2. Copy the *contents* of `OTX_ETX/c480x320/SD` to the root of the card, then
   the contents of `OTX_ETX/color_common/SD` as well. `WIDGETS/` and `IMAGES/`
   end up next to the folders already on the card, existing files are replaced.
3. Eject the drive and unplug the USB cable.
4. On the radio, open the model, go to *Model setup* and set the external module
   to CRSF. In the ExpressLRS Lua script set the packet rate to 500 Hz and the
   telemetry ratio to 1:8, the settings the firmware paces its output for.
5. Power up the flight controller, open the model's *Telemetry* page and run
   *Discover new sensors*. Confirm that an `FM` sensor shows up, that is the
   flight mode name the widget displays.
6. Go to *Screens*, add a screen of type *Widgets*, choose the full screen
   layout and set the widget to `yaapu`.
7. Open *Tools* from the radio menu and run *Yaapu Config* once, so a
   configuration file is written for this model. Long pressing *Menu* on the
   widget screen reopens it later.

## Install on a radio (Boxer, GX12)

Same USB storage step, but copy the contents of `OTX_ETX/bw128x64/SD` and
`OTX_ETX/bw_common/SD` to the card root. Set the module and the sensors up as
above, then open the model's *Telemetry* page, scroll to *Screen 1*, set it to
*Script* and pick `yaapu7`. Run *Yaapu Config* from *Tools* once.

## ELRS link settings and telemetry budget

The firmware paces its telemetry for ELRS 2.4 GHz at a **500 Hz packet rate
with a 1:8 telemetry ratio**. Set both in the ELRS Lua script on the radio
(`Tools`, then `ExpressLRS`). At that setting the receiver sends 62 telemetry
packets per second, which ELRS rates at 2343 bit/s, about 293 bytes/s of CRSF
frames, and the same channel carries the receiver's link statistics.

The default firmware periods use roughly 230 bytes/s of that:

| Frame                              | Rate    | Bytes/s |
| ---------------------------------- | ------- | ------- |
| Attitude and heading (passthrough) | 10 Hz   | 180     |
| GPS position                       | 1 Hz    | 19      |
| Status, GPS status, home           | 0.5 Hz  | 12      |
| Flight mode name (`FM`)            | 0.5 Hz plus every mode change | 7 |
| Battery (CRSF and passthrough)     | 0.33 Hz | 8       |
| Frame type parameter               | 0.25 Hz | 3       |

Status texts (ready, armed, disarmed, failsafe) and every flight mode change
are sent the moment they happen, ahead of the scheduled frames. The two
fastest periods are Kconfig options (`CONFIG_RDD2_CRSF_TELEMETRY_ATTITUDE_PERIOD_MS`
and `CONFIG_RDD2_CRSF_TELEMETRY_STATUS_PERIOD_MS`). A 1:16 ratio halves the
budget and needs the attitude period raised to 500 ms; a poorer ratio (1:32
and below) makes the screen lag, because the receiver drops frames it cannot
fit rather than queueing them.

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
