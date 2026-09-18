# Host tests

Run `tests/check.sh`: it compiles every script under `OTX_ETX/` and then runs the
TX15 widget and the Boxer/GX12 telemetry script under a stubbed EdgeTX API
(`edgetx_stub.lua`), fed with the CRSF frames in `frames.hex` that the Cerebri
encoder self-check produced. Each check prints PASS or FAIL and the script exits
non zero on any wrong value or Lua error.

The Boxer/GX12 sweep drives the telemetry script with the key events the radio
sends, so the HUD, the minimal HUD, the alternate view, both left and right
panel layouts, the message page and the config menu are each drawn at least
once, with frames still arriving in between; it also runs one script per frame
type for the vehicle libraries, drives the Yaapu Config tool, and finishes with
a seeded random walk over the same keys. A coverage list at the end fails if a
library under `SCRIPTS/TELEMETRY/yaapu/` was never loaded.

Needs Lua 5.3 with `bit32` (`LUA_COMPAT_5_2`); set `LUA` and `LUAC` if they are
not `lua5.3`/`luac5.3`.
