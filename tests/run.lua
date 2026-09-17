--
-- Runs the Yaapu scripts on the host against the CRSF frames captured from the
-- Cerebri encoder self-check (frames.hex) and checks what they decode, publish
-- as EdgeTX sensors and draw.
--
local dir = arg[0]:match("^(.*)/[^/]+$") or "."
local repo = dir .. "/.."
local stub = dofile(dir .. "/edgetx_stub.lua")
local scratch = (os.getenv("TMPDIR") or "/tmp") .. "/yaapu-harness"

assert(bit32, "this Lua has no bit32, build 5.3 with LUA_COMPAT_5_2")

local failures = 0

local function check(name, ok, detail)
  print((ok and "PASS  " or "FAIL  ") .. name .. (detail ~= nil and ("  " .. tostring(detail)) or ""))
  if not ok then failures = failures + 1 end
  return ok
end

local function near(name, got, want, tol, wrap)
  if type(got) ~= "number" then
    return check(name, false, "got " .. tostring(got))
  end
  local d = math.abs(got - want)
  if wrap then d = d % wrap d = math.min(d, wrap - d) end
  check(name, d <= tol + 1e-9, string.format("got %.4g want %.4g (tol %.4g)", got, want, tol))
end

local function protect(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    check(name, true)
  else
    check(name, false, "Lua error")
    print(err)
  end
  return ok
end

-------------------------------------------------------------------------------
-- fixture
-------------------------------------------------------------------------------
-- A frame line is "TYPE <hex> PAYLOAD <hex> <hex> ...", preceded by a comment
-- line holding the encoder inputs as key=value tokens, one or more packets per
-- line separated by ";".
local function parseTokens(line)
  local t = {}
  line = line:gsub('([%w_]+)%s*=%s*"([^"]*)"', function(k, v) t[k] = v return " " end)
  for k, v in line:gmatch('([%w_]+)=([^%s;]+)') do t[k] = tonumber(v) or v end
  return t
end

local function parseFrames(text)
  local frames, tokens = {}, {}
  for line in text:gmatch("[^\r\n]+") do
    if line:match("^%s*#") then
      tokens = parseTokens(line)
    elseif line:match("%S") then
      local bytes = {}
      for word in line:gmatch("%S+") do
        if word:match("^%x%x$") then bytes[#bytes + 1] = tonumber(word, 16) end
      end
      if #bytes > 1 then
        frames[#frames + 1] = {
          ftype = bytes[1],
          bytes = table.move(bytes, 2, #bytes, 1, {}),
          tokens = tokens,
        }
      end
      tokens = {}
    end
  end
  return frames
end

local frames = parseFrames(stub.slurp(dir .. "/frames.hex"))

-- How each encoder input maps onto a field of the script's telemetry table.
-- scale converts the fixture unit to the script unit, tol is in script units.
local decoded = {
  roll     = { field = "roll",        tol = 0.1 },                     -- 0.2 deg steps
  pitch    = { field = "pitch",       tol = 0.1 },
  yaw      = { field = "yaw",         tol = 0.1, wrap = 360 },
  vspeed   = { field = "vSpeed",      tol = 0.5, scale = 10 },         -- m/s -> dm/s
  hspeed   = { field = "hSpeed",      tol = 0.5, scale = 10 },
  mode     = { field = "flightMode",  tol = 0,   offset = 1 },         -- wire field is mode+1
  armed    = { field = "statusArmed", tol = 0 },
  failsafe = { field = "failsafe",    tol = 0 },
  sats     = { field = "numSats",     tol = 0 },
  fix      = { field = "gpsStatus",   tol = 0 },
  hdop     = { field = "gpsHdopC",    tol = 0.5, scale = 10 },         -- m -> dm
  throttle = { field = "throttle",    tol = 2,   scale = 0.1 },        -- per mille -> percent
}

-- expectations come from the frames the script actually sees, EdgeTX decodes
-- the rest (0x02 GPS, 0x08 battery, 0x21 flight mode) on its own
local expected, fmName = {}, nil
for _, f in ipairs(frames) do
  if f.ftype == 0x80 then
    for k, v in pairs(f.tokens) do expected[k] = v end
  elseif f.ftype == 0x21 then
    local s = {}
    for _, b in ipairs(f.bytes) do
      if b == 0 then break end
      s[#s + 1] = string.char(b)
    end
    fmName = table.concat(s)
  end
end

local function feed()
  for _, f in ipairs(frames) do stub.pushFrame(f.ftype, f.bytes) end
end

-------------------------------------------------------------------------------
-- checks common to both scripts
-------------------------------------------------------------------------------
local function checkDecoded(label)
  local t = stub.telemetry
  if not check(label .. ": telemetry table captured", t ~= nil) then return end
  for token, m in pairs(decoded) do
    if expected[token] ~= nil then
      near(string.format("%s: %s=%s -> telemetry.%s", label, token, tostring(expected[token]), m.field),
        t[m.field], expected[token] * (m.scale or 1) + (m.offset or 0), m.tol, m.wrap)
    end
  end
end

local function checkSensors(label, list)
  local t = stub.telemetry
  for _, s in ipairs(list) do
    local got = stub.sensors[s[1]]
    if got == nil then
      check(label .. ": sensor " .. s[1] .. " published", false, "never set")
    else
      near(label .. ": sensor " .. s[1], got, s[2](t), 0.001)
    end
  end
end

-------------------------------------------------------------------------------
-- the TX15 widget
-------------------------------------------------------------------------------
local function runWidget()
  local label = "c480x320 widget"
  stub.reset {
    roots = { repo .. "/OTX_ETX/c480x320/SD", repo .. "/OTX_ETX/color_common/SD" },
    scratch = scratch .. "/c480x320",
    model = "modelname", radio = "tx15", lcdw = 480, lcdh = 320,
  }

  local w
  if not protect(label .. ": load", function()
    w = assert(loadScript("/WIDGETS/yaapu/main.lua"), "main.lua not found")()
    assert(type(w.create) == "function" and type(w.refresh) == "function", "not a widget")
  end) then return end

  local widget
  feed()
  if not protect(label .. ": create", function()
    widget = w.create({ x = 0, y = 0, w = 480, h = 320, zone = 0 }, { ["Screen Type"] = 1 })
  end) then return end

  protect(label .. ": background with frames", function()
    for _ = 1, 12 do feed() stub.tick() w.background(widget) end
  end)

  protect(label .. ": refresh with frames", function()
    for _ = 1, 24 do feed() stub.tick() w.refresh(widget) end
  end)

  protect(label .. ": refresh with empty queue", function()
    for _ = 1, 8 do stub.tick() w.refresh(widget) end
  end)

  checkDecoded(label)
  checkSensors(label, { { "VSpd", function(t) return t.vSpeed end } })
  check(label .. ": draws flight mode " .. tostring(fmName), stub.drewText(fmName))

  -- the other screens: messages, min/max, dual battery
  for page = 2, 4 do
    widget.options["Screen Type"] = page
    protect(label .. ": screen type " .. page, function()
      for _ = 1, 10 do feed() stub.tick() w.refresh(widget) end
      for _ = 1, 4 do stub.tick() w.background(widget) end
    end)
    -- the page going to the background is what clears its display flags
    w.background(widget)
  end
  widget.options["Screen Type"] = 1

  -- "FM" sensor not discovered yet: EdgeTX returns nil until the sensor exists
  -- and 0 for an empty one, both must fall back without an error
  protect(label .. ": refresh without the FM sensor", function()
    for _, fm in ipairs({ "nil", 0 }) do
      stub.setFlightModeName(fm ~= "nil" and fm or nil)
      for _ = 1, 10 do stub.tick() w.refresh(widget) w.background(widget) end
    end
  end)
end

-------------------------------------------------------------------------------
-- the Boxer/GX12 telemetry script
-------------------------------------------------------------------------------
local function runScript()
  local label = "bw128x64 script"
  stub.reset {
    roots = { repo .. "/OTX_ETX/bw128x64/SD", repo .. "/OTX_ETX/bw_common/SD" },
    scratch = scratch .. "/bw128x64",
    model = "yaapudev", radio = "boxer", lcdw = 128, lcdh = 64,
  }

  local s
  if not protect(label .. ": load", function()
    s = assert(loadScript("/SCRIPTS/TELEMETRY/yaapu7.lua"), "yaapu7.lua not found")()
    assert(type(s.run) == "function" and type(s.init) == "function", "not a telemetry script")
  end) then return end

  feed()
  if not protect(label .. ": init", function() s.init() end) then return end

  -- the first run() loads the config and returns, telemetry is only popped
  -- from background(), which EdgeTX keeps calling while the screen is visible
  protect(label .. ": first run loads the config", function() s.run(0) end)

  protect(label .. ": background with frames", function()
    for _ = 1, 12 do feed() stub.tick() s.background() end
  end)

  protect(label .. ": run with frames", function()
    for _ = 1, 24 do feed() stub.tick() s.background() s.run(0) end
  end)

  protect(label .. ": run with empty queue", function()
    for _ = 1, 8 do stub.tick() s.background() s.run(0) end
  end)

  checkDecoded(label)
  checkSensors(label, {
    { "ARM",  function(t) return t.statusArmed * 100 end },
    { "IMUt", function(t) return t.imuTemp end },
    { "GAlt", function(t) return math.floor(t.gpsAlt * 0.1) end },
  })
  check(label .. ": draws flight mode " .. tostring(fmName), stub.drewText(fmName))

  protect(label .. ": run without the FM sensor", function()
    for _, fm in ipairs({ "nil", 0 }) do
      stub.setFlightModeName(fm ~= "nil" and fm or nil)
      for _ = 1, 10 do stub.tick() s.background() s.run(0) end
    end
  end)
end

-------------------------------------------------------------------------------
print(string.format("%d frames from %s/frames.hex", #frames, dir))
runWidget()
runScript()
print(failures == 0 and "ALL CHECKS PASSED" or (failures .. " CHECK(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
