-- Squircle PNGs rendered by the helper (theme menu), cached by parameters.
local config = require("config")
local color = require("lib.color")

local M = {}
local dir = config.cache .. "/assets"
os.execute("mkdir -p '" .. dir .. "' && find '" .. dir .. "' -name '*.png' -mtime +14 -delete 2>/dev/null")

local known = {}
local function exists(path)
  if known[path] then return true end
  local f = io.open(path, "r")
  if f then
    f:close()
    known[path] = true
    return true
  end
  return false
end

local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

-- A spec: { path = <png>, kind = "shape", args = <helper args> }.
function M.squircle(w, h, r, fill, stroke, stroke_width)
  stroke, stroke_width = stroke or 0, stroke_width or 0
  local path = string.format("%s/sq_%dx%g_r%g_%08x_%08x_%g.png", dir, w, h, r, fill, stroke, stroke_width)
  return {
    path = path,
    kind = "shape",
    args = string.format("%d %g %g %s %s %g %s", w, h, r, color.hex(fill), color.hex(stroke), stroke_width, q(path)),
  }
end

-- Renders every missing asset in one helper process, then cb().
function M.ensure(specs, cb)
  local groups = { shape = {} }
  local missing = false
  for _, s in ipairs(specs) do
    if not exists(s.path) then
      table.insert(groups[s.kind], s.args)
      missing = true
    end
  end
  if not missing then return cb() end

  local h = q(config.helper)
  local cmds = {}
  if #groups.shape > 0 then table.insert(cmds, h .. " shape " .. table.concat(groups.shape, " ")) end
  sbar.exec(table.concat(cmds, "; "), function() cb() end)
end

return M
