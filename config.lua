-- Geometry, fonts and paths. Everything visual derives from these numbers.
local home = os.getenv("HOME")
local dir = os.getenv("CONFIG_DIR") or (home .. "/.config/sketchybar")

local M = {
  dir    = dir,
  helper = dir .. "/helper/bin/barhelper",
  cache  = home .. "/.cache/sketchybar",
  state  = home .. "/.local/state/sketchybar",

  -- One gap everywhere (screen edge → island → window → window → edge, and
  -- between islands). The bar fills the notch strip (safe area = 32pt on the
  -- 16" panel); islands hang from the top edge by `gap` and end flush with the
  -- strip, so they are 32 - gap tall. aerospace.toml gaps use the same number.
  bar    = { height = 32, gap = 6 },
  -- Active window border (JankyBorders, patched): half of `width` sticks out of
  -- the window; `glow` is the blur radius of the glow around it.
  border = { width = 4, glow = 10 },
  -- The built-in panel's top corners are physically rounded; the helper
  -- daemon masks the bottom ones to match with Apple's continuous corner of
  -- this radius (the curve reaches ~1.53 r along each edge). 0 = off.
  screen_corner = 21,
  -- popups (battery tooltip, theme menu) float this far below the islands;
  -- height: a one-row popup (a theme menu row with its padding)
  popup  = { height = 34, radius = 11, offset = 7 },

  font = {
    text   = "SF Pro Text",
    -- Text weight, picked in the right-click menu (lib/theme.lua keeps the
    -- choice): primary text (workspace digits, clock, layout) in `bold`,
    -- secondary (date, tooltip, menu) one step lighter in `medium`.
    weights = { "Regular", "Medium", "Semibold" },
    lighter = { Regular = "Light", Medium = "Regular", Semibold = "Medium" },
    bold   = "Medium",
    medium = "Regular",
    size   = 12.5,
    -- sketchybar centers the line box; caps sit ~0.75pt low without this
    y_offset = 1,
  },

  anim = { curve = "tanh", frames = 14 },
}

-- Islands hang `gap` from the top and end flush with the bar (the notch
-- strip): 32 - gap tall. Island radius = h / (2 * 1.528): the largest radius
-- at which Apple's continuous corner still fits without being clamped. Inner
-- pills are concentric (inset 3).
do
  local g = M.bar.gap
  local h = M.bar.height - g
  local r = math.floor(h / (2 * 1.528) * 4 + 0.5) / 4
  M.bar.margin = g
  M.island = { height = h, radius = r, gap = g, stroke = 1 }
  M.pill = { height = h - 6, radius = r - 3, inset = 3 }
  M.app_icon_size = h - 8
end

-- A display whose menu bar is lower than the bar gets a shorter strip (the
-- auto-hidden menu bar must cover the islands when it slides in). Its islands
-- are the same islands scaled down as a whole (`scale`, rendered at a higher
-- pixel density, so still crisp); items are centered in the bar, hence the
-- y_offset that keeps them `gap` below the top.
function M.strip(strip)
  local g = M.bar.gap
  local h = strip - g
  return {
    strip = strip,
    scale = h / M.island.height,
    y_offset = (M.bar.height - h) / 2 - g,
    island = M.island,
    pill = M.pill,
  }
end
M.bar.y_offset = M.strip(M.bar.height).y_offset

-- Strip height on a display with a menu bar `menu_bar` pt tall (0 = unknown).
function M.strip_height(menu_bar)
  if menu_bar and menu_bar > 0 then return math.min(M.bar.height, menu_bar) end
  return M.bar.height
end

-- Main screen geometry (width of the areas left/right of the notch) and backing scale.
local out = require("lib.sh").run("'" .. M.helper .. "' geometry 2>/dev/null")
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
