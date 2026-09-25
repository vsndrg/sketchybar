-- Accent state: "auto" follows the wallpaper, "custom" is a fixed color.
-- Every visual that depends on the accent subscribes via theme.on(fn).
local config = require("config")
local color = require("lib.color")

local M = {
  mode = "auto",
  custom = 0xff0a84ff,
  wallpaper = 0xffc9ced6,
  preview = nil,
  listeners = {},
}

-- macOS accent colors (dark appearance).
M.presets = {
  0xff0a84ff, -- blue
  0xffbf5af2, -- purple
  0xffff375f, -- pink
  0xffff453a, -- red
  0xffff9f0a, -- orange
  0xffffd60a, -- yellow
  0xff30d158, -- green
  0xff98989d, -- graphite
}

local state_file = config.state .. "/theme"
local borders_file = config.state .. "/borders"
os.execute("mkdir -p '" .. config.state .. "'")

local function load()
  local f = io.open(state_file, "r")
  if not f then return end
  for line in f:lines() do
    local k, v = line:match("^(%w+)=(.+)$")
    if k == "mode" and (v == "auto" or v == "custom") then M.mode = v end
    if k == "custom" then M.custom = color.parse(v) or M.custom end
    if k == "wallpaper" then M.wallpaper = color.parse(v) or M.wallpaper end
  end
  f:close()
end

local function save()
  local f = io.open(state_file, "w")
  if not f then return end
  f:write("mode=", M.mode, "\n", "custom=", color.hex(M.custom), "\n", "wallpaper=", color.hex(M.wallpaper), "\n")
  f:close()
end

function M.accent()
  if M.preview then return M.preview end
  return M.mode == "custom" and M.custom or M.wallpaper
end

-- Every tone keeps the accent's hue but has a fixed perceptual lightness, so
-- any wallpaper (or custom pick) yields the same contrast.
function M.palette()
  local a = M.accent()
  local white = 0xfff5f5f7
  return {
    accent = a,
    island = color.tone(a, 0.22, 0.015, 0.88), -- near-neutral dark glass, hint of hue
    stroke = 0x17ffffff,
    pill   = color.tone(a, 0.58, 0.13),        -- the accent as a selection: vivid, white text reads
    popup  = color.tone(a, 0.25, 0.015, 0.96),
    glow   = color.tone(a, 0.80, 0.14),        -- window borders: bright against any wallpaper
    text   = white,
    muted  = color.alpha(white, 0.72),
    dim    = color.alpha(white, 0.45),
    red    = 0xffff453a,
  }
end

function M.on(fn)
  table.insert(M.listeners, fn)
end

local last_borders = nil
-- ax_focus=off: borders silently switches to the slow accessibility API when
-- its parent (aerospace) has accessibility rights, which delays the active
-- border. Inactive borders stay transparent: on a workspace switch aerospace
-- moves every window at once and their borders visibly lag behind.
local function apply_borders(a)
  local args = string.format('active_color="glow(%s)" inactive_color=0x00000000 width=6.0 ax_focus=off', color.hex(a))
  if args == last_borders then return end
  last_borders = args
  local f = io.open(borders_file, "w")
  if f then f:write(args, "\n") f:close() end
  sbar.exec("pgrep -xq borders && borders " .. args)
end

function M.apply()
  local p = M.palette()
  for _, fn in ipairs(M.listeners) do fn(p) end
  apply_borders(p.glow)
end

function M.set_wallpaper(c)
  if not c or c == M.wallpaper then return end
  M.wallpaper = c
  save()
  if M.mode == "auto" and not M.preview then M.apply() end
end

function M.set_auto()
  M.preview = nil
  M.mode = "auto"
  save()
  M.apply()
end

function M.set_custom(c)
  M.preview = nil
  M.mode = "custom"
  M.custom = c
  save()
  M.apply()
end

function M.set_preview(c)
  M.preview = c
  M.apply()
end

load()
return M
