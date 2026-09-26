-- Whole islands rendered by the helper as single images.
--
-- On macOS 26+ sketchybar can't freeze screen updates: window moves/resizes
-- and content land on screen in different frames. So each side of the bar is
-- ONE item of a FIXED width showing ONE image: every state change is a pure
-- content swap of a single window — exactly one frame, nothing ever jumps.
-- Images are content-addressed and cached.
local config = require("config")
local sh = require("lib.sh")

local M = {}
local dir = config.cache .. "/islands"
-- leftovers of previous runs (this run's images are tracked by M.gc)
sh.run("mkdir -p '" .. dir .. "' && find '" .. dir .. "' -name '*.png' -mmin +60 -delete 2>/dev/null")

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

-- 64-bit FNV-1a (Lua integers wrap at 64 bits): the cache holds thousands of
-- images, where a 32-bit key would eventually collide and show a stale one.
local function fnv1a(s)
  local h = -3750763034362895579 -- 0xcbf29ce484222325
  for i = 1, #s do
    h = (h ~ s:byte(i)) * 1099511628211 -- 0x100000001b3
  end
  return string.format("%016x", h)
end

local meta = {} -- out path -> { width, ranges, out }
local used = {} -- out path -> os.time() of last use
local pinned = {} -- owner -> { out path, ... }: shown by the daemon, never collected

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
  local now = os.time()
  for _, j in ipairs(jobs) do used[j.out] = now end
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

-- Every state is a new content-addressed PNG (the clock alone adds one per
-- minute), so drop images that haven't been used for `max_age` seconds.
-- Deleting one that is on screen is harmless: sketchybar keeps it in memory,
-- and a later cache miss simply re-renders it.
function M.gc(max_age)
  local cutoff = os.time() - max_age
  local keep = {}
  for _, list in pairs(pinned) do
    for _, path in ipairs(list) do keep[path] = true end
  end
  for path, t in pairs(used) do
    if t < cutoff and not keep[path] then
      os.remove(path)
      used[path] = nil
      meta[path] = nil
    end
  end
end

-- A fixed-size canvas of islands (see helper renderRow). geo: a strip
-- geometry (config.strip): the image is shown scaled by geo.scale.
function M.row(opts, geo)
  opts.kind = "row"
  opts.h = config.island.height
  if geo and geo.scale ~= 1 then opts.scale = geo.scale end
  return M.job(opts)
end

-- Images the daemon shows on demand (the menu) may sit unused for hours:
-- keep an owner's current ones out of M.gc.
function M.pin(owner, paths)
  pinned[owner] = paths
end

-- A menu (helper layoutMenu: opts.w x opts.h, entries laid out by the caller,
-- its shadow in a margin opts.m around it) as a canvas of its own.
function M.menu(opts, geo)
  opts.kind = "menu"
  local m = opts.m or 0
  local row = { kind = "row", h = opts.h + 2 * m, canvas_w = opts.w + 2 * m, islands = { opts } }
  if geo and geo.scale ~= 1 then row.scale = geo.scale end
  return M.job(row)
end

-- Shared island style for jobs.
function M.base(kind, palette)
  local color = require("lib.color")
  local island = config.island
  return {
    kind = kind,
    h = island.height,
    r = island.radius,
    fill = color.hex(palette.island),
    stroke = color.hex(palette.stroke),
    sw = island.stroke,
  }
end

return M
