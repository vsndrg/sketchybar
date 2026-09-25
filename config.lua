-- Geometry, fonts and paths. Everything visual derives from these numbers.
local home = os.getenv("HOME")
local dir = os.getenv("CONFIG_DIR") or (home .. "/.config/sketchybar")

local M = {
  dir    = dir,
  helper = dir .. "/helper/bin/barhelper",
  cache  = home .. "/.cache/sketchybar",
  state  = home .. "/.local/state/sketchybar",

  -- Bar fills the notch strip (safe area = 32pt on the 16" panel); side margin
  -- matches aerospace outer gaps so islands line up with window edges.
  bar    = { height = 32, margin = 10 },

  -- Island radius = h / (2 * 1.528): the largest radius at which Apple's
  -- continuous corner still fits without being clamped. Inner pills are
  -- concentric: inset 3 → radius 8.5 - 3.
  island = { height = 26, radius = 8.5, gap = 6, stroke = 1 },
  pill   = { height = 20, radius = 5.5, inset = 3 },
  popup  = { height = 34, radius = 11 },

  app_icon_size = 18,

  font = {
    text   = "SF Pro Text",
    medium = "Medium",
    bold   = "Semibold",
    size   = 12.5,
    -- sketchybar centers the line box; caps sit ~0.75pt low without this
    y_offset = 1,
  },

  anim = { curve = "tanh", frames = 14 },
}

-- Main screen geometry (width of the areas left/right of the notch) and backing scale.
local f = io.popen("'" .. M.helper .. "' geometry 2>/dev/null")
local out = f and f:read("*a") or ""
if f then f:close() end
M.geometry = out:gsub("%s+$", "") -- raw, to detect a real change of the main screen later
local w, l, r, s = out:match("(%d+) (%d+) (%d+) ([%d%.]+)")
M.screen = {
  width = tonumber(w) or 1728,
  left  = tonumber(l) or 864,
  right = tonumber(r) or 864,
  scale = tonumber(s) or 2,
}

-- App icons come back at 32pt; helper PNGs are rendered at backing scale.
M.app_icon_scale = M.app_icon_size / 32
M.image_scale = 1 / M.screen.scale

-- Each side is one fixed-width item from the screen edge towards the notch.
-- The right one (status, the same item on every display) is capped to what its
-- content needs, so it fits any display; the left one (workspaces) is one item
-- per display, sized per display by M.left_width.
M.status_max = 320
M.side_width = {
  right = math.min(M.screen.right - M.bar.margin - 8, M.status_max),
}

-- Workspaces width on a display (w wide; notch_left: width left of its notch, 0 = none).
function M.left_width(w, notch_left)
  if notch_left > 0 then return notch_left - M.bar.margin - 8 end
  return w - 2 * M.bar.margin - M.side_width.right - 8
end

return M
