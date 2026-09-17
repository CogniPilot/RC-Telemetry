--
-- Host side stubs of the EdgeTX Lua API, enough to run the Yaapu telemetry
-- scripts under plain Lua 5.3 and observe what they decode and draw.
--
-- stub.reset{roots=..., model=..., lcdw=..., lcdh=...}  prepare a fresh run
-- stub.pushFrame(type, bytes)                           queue a CRSF frame
-- stub.setFlightModeName(s)                             what getValue("FM") returns
-- stub.calls                                            recorded API calls
-- stub.sensors                                          last setTelemetryValue per name
-- stub.telemetry                                        the script's telemetry table
--
local stub = {}

-- host io, kept before the EdgeTX flavour replaces the global one
local hostOpen, hostPopen = io.open, io.popen

-------------------------------------------------------------------------------
-- SD card emulation
-------------------------------------------------------------------------------
-- The radio's FAT filesystem is case insensitive and the scripts mix cases
-- ("/WIDGETS/Yaapu/" and "/WIDGETS/YAAPU/CFG/"), so paths are resolved through
-- a lowercased index of the SD trees. Writes never touch the source tree, they
-- land in a scratch directory and are indexed so later reads find them.
local index = {}
local scratch

local function normalize(path)
  path = path:gsub("//+", "/")
  while true do
    local p, n = path:gsub("/[^/]+/%.%./", "/", 1)
    path = p
    if n == 0 then return path end
  end
end

local function resolve(path)
  return index[normalize(path):lower()]
end

local function buildIndex(roots)
  index = {}
  for _, root in ipairs(roots) do
    root = root:gsub("/+$", "")
    local p = assert(hostPopen("find '" .. root .. "' -mindepth 1"))
    for line in p:lines() do
      index[line:sub(#root + 1):lower()] = line
    end
    p:close()
  end
end

-------------------------------------------------------------------------------
-- constants
-------------------------------------------------------------------------------
-- Every ALL_CAPS global the scripts read is an EdgeTX constant (colours, text
-- flags, EVT_*); each name gets its own small integer on first use. Unknown
-- lower case globals stay nil, exactly as in EdgeTX, so a call to a misspelled
-- API still fails loudly.
local nextConst = 1
setmetatable(_G, {
  __index = function(t, k)
    if type(k) == "string" and k:match("^[A-Z][A-Z0-9_]*$") then
      nextConst = nextConst + 1
      rawset(t, k, nextConst)
      return nextConst
    end
    return nil
  end,
})

-------------------------------------------------------------------------------
-- EdgeTX runs Lua 5.2 where string.format("%d", 1.5) truncates instead of
-- raising "number has no integer representation", and where math.pow exists.
-------------------------------------------------------------------------------
local rawFormat = string.format

local function truncate(v)
  return math.tointeger(v) or (v < 0 and math.ceil(v) or math.floor(v))
end

string.format = function(fmt, ...)
  local args = table.pack(...)
  local i = 0
  for conv in tostring(fmt):gmatch("%%[-+ #0]*%d*%.?%d*([diouxXcqfeEgGsaA%%])") do
    if conv ~= "%" then
      i = i + 1
      if conv:match("[diouxXc]") and type(args[i]) == "number" then
        args[i] = truncate(args[i])
      end
    end
  end
  return rawFormat(fmt, table.unpack(args, 1, args.n))
end

math.pow = math.pow or function(a, b) return a ^ b end

-------------------------------------------------------------------------------
-- recorders
-------------------------------------------------------------------------------
local function record(name, ...)
  local t = stub.calls[name]
  if t == nil then
    t = {}
    stub.calls[name] = t
  end
  t[#t + 1] = table.pack(...)
  return t
end

-- The scripts keep their telemetry table local but hand it to every library
-- they load, so it is picked up from the arguments of the loaded functions.
local function isTelemetry(t)
  return type(t) == "table" and t.statusArmed ~= nil and t.numSats ~= nil
     and t.roll ~= nil and t.gpsHdopC ~= nil
end

local function instrument(chunk)
  return function(...)
    local ret = chunk(...)
    if type(ret) == "table" then
      for k, v in pairs(ret) do
        if type(v) == "function" then
          ret[k] = function(...)
            for i = 1, select("#", ...) do
              if isTelemetry((select(i, ...))) then stub.telemetry = (select(i, ...)) end
            end
            return v(...)
          end
        end
      end
    end
    return ret
  end
end

-------------------------------------------------------------------------------
-- the API
-------------------------------------------------------------------------------
function loadScript(path)
  local real = resolve(path)
  if real == nil then return nil end
  return instrument(assert(loadfile(real)))
end

io = {
  open = function(name, mode)
    local real
    if mode ~= nil and mode:find("[wa]") then
      real = scratch .. "/" .. normalize(name):lower():gsub("[/\\]", "_")
      index[normalize(name):lower()] = real
    else
      real = resolve(name)
    end
    if real == nil then return nil end
    return hostOpen(real, mode or "r")
  end,
  read = function(f, n) return f:read(n) or "" end,
  write = function(f, s) return f:write(s) end,
  close = function(f) return f:close() end,
}

Bitmap = {
  open = function(path) return resolve(path) and {path = path} or nil end,
  getSize = function(bm) if bm == nil then return 0, 0 end return 32, 32 end,
}

lcd = {}
function lcd.clear() record("clear") end
function lcd.setColor(idx, c) record("setColor", idx, c) end
function lcd.RGB(r, g, b) return (r or 0) * 65536 + (g or 0) * 256 + (b or 0) end
function lcd.resetBacklightTimeout() end
function lcd.drawText(x, y, text, flags)
  stub.lastLeft, stub.lastRight = x, x + 6 * #tostring(text)
  record("drawText", x, y, tostring(text), flags)
end
function lcd.drawNumber(x, y, value, flags)
  stub.lastLeft, stub.lastRight = x, x + 30
  record("drawNumber", x, y, value, flags)
end
function lcd.drawTimer(x, y, value, flags) record("drawTimer", x, y, value, flags) end
function lcd.drawLine(...) record("drawLine", ...) end
function lcd.drawLineWithClipping(...) record("drawLine", ...) end
function lcd.drawPoint(...) record("drawPoint", ...) end
function lcd.drawRectangle(...) record("drawRectangle", ...) end
function lcd.drawFilledRectangle(...) record("drawFilledRectangle", ...) end
function lcd.drawGauge(...) record("drawGauge", ...) end
function lcd.drawHudRectangle(...) record("drawHudRectangle", ...) end
function lcd.drawBitmap(bm, x, y, scale) record("drawBitmap", bm, x, y, scale) end
function lcd.getLastLeftPos() return stub.lastLeft or 0 end
function lcd.getLastRightPos() return stub.lastRight or 0 end

function getTime() return stub.now end
function getRSSI() return stub.rssi end
function getVersion() return "2.11.0", stub.radio, 2, 11, 0, "EdgeTX" end
function getGeneralSettings()
  return { imperial = 0, language = "en", voice = "en", gtimer = 0, battMin = 9, battMax = 12 }
end
function getDateTime()
  return { year = 2026, mon = 1, day = 1, hour = 12, min = 30, sec = 15 }
end
function getFieldInfo(name) return { id = 1, name = name, desc = name, unit = 0, prec = 0 } end
function getValue(id)
  if id == "FM" then return stub.fm end
  return 0
end
function setTelemetryValue(id, subId, instance, value, unit, prec, name)
  stub.sensors[name] = value
  record("setTelemetryValue", id, subId, instance, value, unit, prec, name)
end
function playFile(f) record("playFile", f) end
function playNumber(...) record("playNumber", ...) end
function playDuration(...) record("playDuration", ...) end
function playTone(...) record("playTone", ...) end
function playHaptic(...) record("playHaptic", ...) end
function killEvents(e) record("killEvents", e) end
function sportTelemetryPop() return nil end
function crossfireTelemetryPush() return true end
function crossfireTelemetryPop()
  local f = stub.queue[stub.queueIdx]
  if f == nil then return nil end
  stub.queueIdx = stub.queueIdx + 1
  return f.type, f.data
end

model = {
  getInfo = function() return { name = stub.model, bitmap = "" } end,
  getTimer = function(i) return stub.timers[i] or { mode = 0, start = 0, value = 0 } end,
  setTimer = function(i, t)
    local cur = stub.timers[i] or { mode = 0, start = 0, value = 0 }
    for k, v in pairs(t) do cur[k] = v end
    stub.timers[i] = cur
  end,
}

-------------------------------------------------------------------------------
-- harness control
-------------------------------------------------------------------------------
function stub.reset(opts)
  buildIndex(opts.roots)
  scratch = assert(opts.scratch, "scratch dir required")
  os.execute("mkdir -p '" .. scratch .. "'")
  stub.model = opts.model
  stub.radio = opts.radio or "tx15"
  stub.rssi = opts.rssi or 70
  stub.now = 1000
  stub.fm = nil
  stub.queue, stub.queueIdx = {}, 1
  stub.calls, stub.sensors, stub.timers = {}, {}, {}
  stub.telemetry = nil
  LCD_W, LCD_H = opts.lcdw, opts.lcdh
end

-- 0x02 (GPS) and 0x08 (battery) are decoded by EdgeTX itself, 0x21 is the
-- flight mode frame EdgeTX turns into the "FM" text sensor. Only the Yaapu
-- passthrough frames reach the script.
function stub.pushFrame(ftype, bytes)
  if ftype == 0x21 then
    local s = {}
    for _, b in ipairs(bytes) do
      if b == 0 then break end
      s[#s + 1] = string.char(b)
    end
    stub.setFlightModeName(table.concat(s))
  elseif ftype ~= 0x02 and ftype ~= 0x08 then
    stub.queue[#stub.queue + 1] = { type = ftype, data = bytes }
  end
end

function stub.setFlightModeName(s) stub.fm = s end

function stub.tick(ticks) stub.now = stub.now + (ticks or 10) end

-- did any lcd.drawText call draw this string?
function stub.drewText(s)
  for _, c in ipairs(stub.calls.drawText or {}) do
    if c[3]:find(s, 1, true) then return true end
  end
  return false
end

-- read a file with host io, for fixtures living outside the SD tree
function stub.slurp(path)
  local f = assert(hostOpen(path, "r"))
  local s = f:read("a")
  f:close()
  return s
end

return stub
