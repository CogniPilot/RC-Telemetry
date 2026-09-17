#!/bin/sh
# Compile every radio script, then run them on the host against the captured
# CRSF frames. Override the interpreter with LUA/LUAC if it is not on PATH.
set -e
cd "$(dirname "$0")/.."
LUA=${LUA:-lua5.3}
LUAC=${LUAC:-luac5.3}
find OTX_ETX -name '*.lua' -print0 | xargs -0 -n1 "$LUAC" -p
exec "$LUA" tests/run.lua
