-- Whole islands rendered by the helper as single images.
--
-- On macOS 26+ sketchybar can't freeze screen updates: window moves/resizes
-- and content land on screen in different frames. So each side of the bar is
-- ONE item of a FIXED width showing ONE image: every state change is a pure
-- content swap of a single window — exactly one frame, nothing ever jumps.
-- Images are content-addressed and cached.
local config = require("config")

local M = {}
local dir = config.cache .. "/islands"
os.execute("mkdir -p '" .. dir .. "' && find '" .. dir .. "' -name '*.png' -mtime +1 -delete 2>/dev/null")

-- Minimal JSON encoder (strings, numbers, booleans, arrays, objects).
local function encode(v)
  local t = type(v)
  if t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c)
      return string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif t == "number" then
    return (math.type(v) == "integer") and tostring(v) or string.format("%.4f", v)
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "table" then
    if #v > 0 or next(v) == nil then
      local out = {}
      for i, x in ipairs(v) do out[i] = encode(x) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys) -- deterministic, so identical jobs hash identically
    local out = {}
    for i, k in ipairs(keys) do out[i] = encode(tostring(k)) .. ":" .. encode(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
  end
  return "null"
end

local function fnv1a(s)
  local h = 2166136261
  for i = 1, #s do
    h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff
  end
  return string.format("%08x", h)
end

local meta = {} -- out path -> { width, ranges, out }

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

-- Finalizes a job: its output path is the hash of its content.
function M.job(j)
  j.out = nil
  local body = encode(j)
  j.out = string.format("%s/%s_%s.png", dir, j.kind, fnv1a(body))
  return j
end

-- Renders missing jobs in one helper process, then cb(list of meta).
function M.run(jobs, cb)
  local todo = {}
  for _, j in ipairs(jobs) do
    if not (meta[j.out] and exists(j.out)) then todo[#todo + 1] = j end
  end
  local function done()
    if not cb then return end
    local out = {}
    for i, j in ipairs(jobs) do out[i] = meta[j.out] end
    cb(out)
  end
  if #todo == 0 then return done() end

  local json = encode(todo):gsub("'", "'\\''")
  sbar.exec("'" .. config.helper .. "' render '" .. json .. "'", function(result)
    if type(result) == "table" then
      for _, m in ipairs(result) do
        if m.out then meta[m.out] = m end
      end
    end
    for _, j in ipairs(jobs) do
      if not meta[j.out] then return end -- render failed; keep the old image
    end
    done()
  end)
end

-- A fixed-size canvas of islands (see helper renderRow).
function M.row(opts)
  opts.kind = "row"
  opts.h = config.island.height
  return M.job(opts)
end

-- Shared island style for jobs.
function M.base(kind, palette)
  local color = require("lib.color")
  return {
    kind = kind,
    h = config.island.height,
    r = config.island.radius,
    fill = color.hex(palette.island),
    stroke = color.hex(palette.stroke),
    sw = config.island.stroke,
  }
end

return M
