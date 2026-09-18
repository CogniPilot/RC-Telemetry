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

-- noFm leaves the "FM" text sensor alone, for the checks that drive the arm
-- state or the vehicle flight mode names themselves
local function feed(noFm)
  for _, f in ipairs(frames) do
    if not (noFm and f.ftype == 0x21) then stub.pushFrame(f.ftype, f.bytes) end
  end
end

-- one Yaapu passthrough packet in the wire form the script parses, the same
-- layout as the 0xF2 frames in frames.hex
local function passthrough(appId, value)
  local b = { 0xF2, 1, appId % 256, math.floor(appId / 256) }
  for i = 0, 3 do b[#b + 1] = math.floor(value / 256 ^ i) % 256 end
  return b
end

-- a 0xF1 status text frame: severity then the zero terminated text
local function statusText(severity, text)
  local b = { 0xF1, severity }
  for i = 1, #text do b[#b + 1] = string.byte(text, i) end
  b[#b + 1] = 0
  return b
end

-------------------------------------------------------------------------------
-- observers
-------------------------------------------------------------------------------
-- which yaapu/ libraries a run loaded, and the union over the runs that reset
-- the stub in between
local loadedLibs = {}

local function libName(path)
  return path:lower():match("/yaapu/([%w_]+)%.lua$")
end

local function libLoaded(name)
  for path in pairs(stub.loaded) do
    if libName(path) == name then return true end
  end
  return false
end

local function recordLoaded()
  for path in pairs(stub.loaded) do
    local name = libName(path)
    if name ~= nil then loadedLibs[name] = true end
  end
end

-- did any lcd.drawText above y draw this string? the bottom bar repeats the
-- last message at y=58, only the message page lists them up the screen
local function drewTextAbove(s, y)
  for _, c in ipairs(stub.calls.drawText or {}) do
    if c[2] < y and c[3]:find(s, 1, true) then return true end
  end
  return false
end

-- did the script hand this sound file to playFile?
local function played(s)
  for _, c in ipairs(stub.calls.playFile or {}) do
    if c[1]:find(s, 1, true) then return true end
  end
  return false
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

  -- the per motor RPM bars are gated by "enable RPM support" (RPM:3)
  local cfgPath = "/WIDGETS/Yaapu/cfg/modelname.cfg"
  local cfg = assert(io.open(cfgPath, "r"))
  local cfgText = io.read(cfg, 500)
  io.close(cfg)
  cfg = assert(io.open(cfgPath, "w"))
  io.write(cfg, cfgText .. ",RPM:3")
  io.close(cfg)

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
  -- the four motor RPM sensors, all labelled "RPM" and told apart by instance
  for i = 1, 4 do
    near(label .. ": RPM sensor instance " .. (i - 1) .. " -> telemetry.rpm" .. i,
      stub.telemetry["rpm" .. i], stub.rpm[i], 0)
  end
  check(label .. ": draws the motor RPM bars", stub.drewText("M4"))

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

  -----------------------------------------------------------------------------
  -- pages and views, driven by the key events EdgeTX hands to run()
  -----------------------------------------------------------------------------
  -- one radio cycle: frames arrive in background(), run() draws the current
  -- page and handles the key event
  local function step(event, noFm)
    feed(noFm)
    stub.tick()
    s.background()
    s.run(event or 0)
  end

  -- the draw library and the panels load one per run(), spread over the eight
  -- values of the script's loadCycle
  local function settle(n)
    for _ = 1, n or 8 do step(0) end
  end

  local function page(name, event)
    protect(label .. ": " .. name, function()
      step(event)
      settle()
    end)
  end

  page("message page", EVT_VIRTUAL_NEXT)
  check(label .. ": the message page lists the status text",
    drewTextAbove("cerebri ready", 58))
  page("message page back to the main view", EVT_VIRTUAL_PREV)
  page("message page again", EVT_VIRTUAL_NEXT)
  page("alternate view", EVT_VIRTUAL_ENTER)
  check(label .. ": the alternate view is loaded", libLoaded("alt7_view"))
  page("message page from the alternate view", EVT_VIRTUAL_NEXT)
  page("alternate view back to the main view", EVT_VIRTUAL_ENTER)
  page("min/max values", EVT_VIRTUAL_MENU)
  page("current values", EVT_VIRTUAL_MENU)
  check(label .. ": the default panels are loaded",
    libLoaded("hud7") and libLoaded("right7") and libLoaded("left7_m2f"))

  -----------------------------------------------------------------------------
  -- the config menu: walk every item, switch the three panel layouts and save
  -----------------------------------------------------------------------------
  -- the item order is the library's own, so the walk follows it
  local menuItems = loadScript("/SCRIPTS/TELEMETRY/yaapu/menu7.lua")().menuItems

  local function itemIndex(name)
    for i = 1, #menuItems do
      if menuItems[i][2] == name then return i end
    end
  end

  protect(label .. ": config menu walks every item", function()
    step(EVT_VIRTUAL_MENU_LONG)
    settle()
    -- one full turn: every item is selected once and the selection wraps back
    for _ = 1, #menuItems do step(EVT_VIRTUAL_NEXT) end
  end)
  check(label .. ": the config menu drew the last item",
    stub.drewText(menuItems[#menuItems][1]))

  protect(label .. ": config menu switches the panel layouts", function()
    local at = 1
    for _, name in ipairs({ "CPANE", "RPANE", "LPANE" }) do
      for _ = at, itemIndex(name) - 1 do step(EVT_VIRTUAL_NEXT) end
      at = itemIndex(name)
      step(EVT_VIRTUAL_ENTER)   -- start editing
      step(EVT_VIRTUAL_NEXT)    -- the other layout file
      step(EVT_VIRTUAL_ENTER)   -- done
    end
    step(EVT_VIRTUAL_EXIT)      -- saves the config and closes the menu
    settle()
  end)

  local cfg = io.open("/MODELS/yaapu/yaapudev.cfg", "r")
  local saved = cfg ~= nil and io.read(cfg, 500) or ""
  if cfg ~= nil then io.close(cfg) end
  check(label .. ": the menu saved CPANE:2 to the config file",
    saved:find("CPANE:2", 1, true) ~= nil, saved)
  check(label .. ": the minimal panels are loaded",
    libLoaded("hud7_min") and libLoaded("right7_min") and libLoaded("left7"))

  -----------------------------------------------------------------------------
  -- status text frames, the message page and the voice path
  -----------------------------------------------------------------------------
  local texts = {
    { 4, "Arming motors" },
    { 4, "Disarming motors" },
    { 2, "Failsafe enabled" },
    -- the 16 byte prefix hash of this one is a known one, so the trailing
    -- number is spoken as well
    { 6, "Reached command #3" },
  }
  page("message page while the status texts arrive", EVT_VIRTUAL_NEXT)
  for _, m in ipairs(texts) do
    protect(label .. ": status text " .. m[2], function()
      stub.pushFrame(0x80, statusText(m[1], m[2]))
      settle(4)
    end)
    check(label .. ": the message page lists " .. m[2], drewTextAbove(m[2], 58))
  end
  -- the hash of the message text names the sound file that is played
  check(label .. ": the message sound file is played", played("/2262475.wav"))
  check(label .. ": the message parameter is spoken",
    (stub.calls.playNumber or {})[1] ~= nil and stub.calls.playNumber[1][1] == 3)
  page("message page back to the main view", EVT_VIRTUAL_PREV)

  -----------------------------------------------------------------------------
  -- arm state from the flight mode string
  -----------------------------------------------------------------------------
  local armed = {}
  protect(label .. ": arm and disarm through the flight mode string", function()
    for _, fm in ipairs({ fmName .. "*", fmName }) do
      stub.setFlightModeName(fm)
      for _ = 1, 12 do step(0, true) end
      armed[#armed + 1] = stub.telemetry.statusArmed
    end
  end)
  check(label .. ": the '*' marker disarms", armed[1] == 0, armed[1])
  check(label .. ": dropping it arms again", armed[2] == 1, armed[2])
  check(label .. ": both callouts are played",
    played("/disarmed.wav") and played("/armed.wav"))

  -----------------------------------------------------------------------------
  -- a flight timer that went backwards is what triggers the telemetry reset
  -----------------------------------------------------------------------------
  protect(label .. ": reset request while armed", function()
    stub.timers[2] = { mode = 0, start = 0, value = 300 }
    for _ = 1, 12 do step(0, true) end
    stub.timers[2].value = 0
    for _ = 1, 12 do step(0, true) end
  end)
  check(label .. ": the reset is refused while armed", stub.drewText("Reset ignored"))

  protect(label .. ": reset request once disarmed", function()
    stub.setFlightModeName(fmName .. "*")
    for _ = 1, 12 do step(0, true) end
    stub.timers[2] = { mode = 0, start = 0, value = 300 }
    for _ = 1, 12 do step(0, true) end
    stub.timers[2].value = 0
    for _ = 1, 12 do step(0, true) end
  end)
  check(label .. ": the reset library ran", libLoaded("reset"))
  page("message page after the reset", EVT_VIRTUAL_NEXT)
  check(label .. ": the reset is announced", drewTextAbove("Telemetry reset", 58))
  page("message page back to the main view", EVT_VIRTUAL_PREV)

  -- the heli layouts ship with the script but nothing selects them, so they
  -- are only loaded here
  protect(label .. ": the heli layouts load", function()
    local view = assert(loadScript("/SCRIPTS/TELEMETRY/yaapu/heli7_view.lua"),
      "heli7_view.lua not found")()
    assert(type(view.drawView) == "function", "heli7_view has no drawView")
    local pane = assert(loadScript("/SCRIPTS/TELEMETRY/yaapu/right7_heli.lua"),
      "right7_heli.lua not found")()
    assert(type(pane.drawPane) == "function", "right7_heli has no drawPane")
  end)

  -----------------------------------------------------------------------------
  -- a seeded random walk over the same keys, with and without frames
  -----------------------------------------------------------------------------
  -- the walk only looks for errors, and a call log that keeps growing would
  -- make every collectgarbage() in the script walk a longer and longer list
  stub.calls = {}
  protect(label .. ": 500 random key events", function()
    local events = { 0, EVT_VIRTUAL_NEXT, EVT_VIRTUAL_PREV, EVT_VIRTUAL_ENTER,
      EVT_VIRTUAL_EXIT, EVT_VIRTUAL_MENU, EVT_VIRTUAL_MENU_LONG,
      EVT_VIRTUAL_ENTER_LONG, EVT_VIRTUAL_NEXT_REPT, EVT_VIRTUAL_PREV_REPT }
    local seed = 20260918
    local function rand(n)
      seed = (seed * 1103515245 + 12345) % 2147483648
      return 1 + (seed // 65536) % n
    end
    for i = 1, 500 do
      if i % 50 == 0 then stub.calls = {} end
      if rand(3) > 1 then feed(true) end
      stub.tick()
      s.background()
      s.run(events[rand(#events)])
    end
  end)

  recordLoaded()
end

-------------------------------------------------------------------------------
-- the vehicle libraries: the frame type parameter picks one, and the first
-- type a script sees is the only one it ever loads, so each gets a fresh run
-------------------------------------------------------------------------------
local vehicles = {
  { 2,  "quadrotor",  "copter", "Acro" },
  { 4,  "helicopter", "copter", "Acro" },
  { 1,  "plane",      "plane",  "Circle" },
  { 10, "rover",      "rover",  "Acro" },
  { 11, "boat",       "rover",  "Acro" },
  { 7,  "airship",    "blimp",  "Manual" },
}

local function runVehicle(v)
  local label = string.format("bw128x64 frame type %d (%s)", v[1], v[2])
  stub.reset {
    roots = { repo .. "/OTX_ETX/bw128x64/SD", repo .. "/OTX_ETX/bw_common/SD" },
    scratch = scratch .. "/bw128x64",
    model = "yaapudev", radio = "boxer", lcdw = 128, lcdh = 64,
  }

  local s
  if not protect(label .. ": load", function()
    s = assert(loadScript("/SCRIPTS/TELEMETRY/yaapu7.lua"), "yaapu7.lua not found")()
  end) then return end

  protect(label .. ": run", function()
    s.init()
    s.run(0)
    -- no "FM" sensor, so the flight mode name comes from the vehicle library
    for _ = 1, 32 do
      feed(true)
      stub.pushFrame(0x80, passthrough(0x5007, 0x01000000 + v[1]))
      stub.tick()
      s.background()
      s.run(0)
    end
  end)
  check(label .. ": loads " .. v[3] .. ".lua", libLoaded(v[3]))
  check(label .. ": draws the flight mode " .. v[4], stub.drewText(v[4]))
  recordLoaded()
end

-------------------------------------------------------------------------------
-- the Yaapu Config tool, the same menu library outside the telemetry script
-------------------------------------------------------------------------------
local function runConfigTool()
  local label = "bw128x64 config tool"
  stub.reset {
    roots = { repo .. "/OTX_ETX/bw128x64/SD", repo .. "/OTX_ETX/bw_common/SD" },
    scratch = scratch .. "/bw128x64",
    model = "yaapudev", radio = "boxer", lcdw = 128, lcdh = 64,
  }

  local t
  if not protect(label .. ": load", function()
    t = assert(loadScript("/SCRIPTS/TOOLS/Yaapu Config.lua"), "Yaapu Config.lua not found")()
    assert(type(t.run) == "function" and type(t.init) == "function", "not a tool")
  end) then return end

  local menuItems = loadScript("/SCRIPTS/TELEMETRY/yaapu/menu7.lua")().menuItems
  local exit
  protect(label .. ": walk every item, change the language and save", function()
    t.init()
    for _ = 1, #menuItems do t.run(EVT_VIRTUAL_NEXT) end
    t.run(EVT_VIRTUAL_ENTER)
    t.run(EVT_VIRTUAL_NEXT)
    t.run(EVT_VIRTUAL_ENTER)
    exit = t.run(EVT_VIRTUAL_EXIT)
  end)
  check(label .. ": drew the last item", stub.drewText(menuItems[#menuItems][1]))
  check(label .. ": exit closes the tool", exit == 1, exit)

  local cfg = io.open("/MODELS/yaapu/yaapudev.cfg", "r")
  local saved = cfg ~= nil and io.read(cfg, 500) or ""
  if cfg ~= nil then io.close(cfg) end
  check(label .. ": the tool saved L1:2 to the config file",
    saved:find("L1:2", 1, true) ~= nil, saved)
  recordLoaded()
end

-------------------------------------------------------------------------------
-- every library under yaapu/ has to have been loaded and run by the sweep
-------------------------------------------------------------------------------
local function checkCoverage()
  for _, name in ipairs({ "alt7_view", "blimp", "copter", "draw7", "heli7_view",
    "hud7", "hud7_min", "left7", "left7_m2f", "menu7", "plane", "reset",
    "right7", "right7_heli", "right7_min", "rover" }) do
    check("bw128x64 libraries: " .. name .. ".lua was loaded", loadedLibs[name] == true)
  end
end

-------------------------------------------------------------------------------
print(string.format("%d frames from %s/frames.hex", #frames, dir))
runWidget()
runScript()
for _, v in ipairs(vehicles) do runVehicle(v) end
runConfigTool()
checkCoverage()
print(failures == 0 and "ALL CHECKS PASSED" or (failures .. " CHECK(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
