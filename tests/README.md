# Host tests

Run `tests/check.sh`: it compiles every script under `OTX_ETX/` and then runs the
TX15 widget and the Boxer/GX12 telemetry script under a stubbed EdgeTX API
(`edgetx_stub.lua`), fed with the CRSF frames in `frames.hex` that the Cerebri
encoder self-check produced. Each check prints PASS or FAIL and the script exits
non zero on any wrong value or Lua error. Needs Lua 5.3 with `bit32`
(`LUA_COMPAT_5_2`); set `LUA` and `LUAC` if they are not `lua5.3`/`luac5.3`.
