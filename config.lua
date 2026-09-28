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
  -- The built-in panel's top corners are physically rounded; the helper
  -- daemon masks the bottom ones to match with Apple's continuous corner of
  -- this radius (the curve reaches ~1.53 r along each edge). 0 = off.
  screen_corner = 21,
  -- popups (battery tooltip, theme menu) float this far below the islands;
  -- height: a one-row popup (a theme menu row with its padding)
  popup  = { height = 34, offset = 7 },

  font = {
    text   = "SF Pro Text",
    -- Text weight, picked in the right-click menu (lib/theme.lua keeps the
    -- choice): primary text (workspace digits, date and time, layout, battery
    -- level) in `bold`, secondary (tooltip, menu) one step lighter in `medium`.
    weights = { "Regular", "Medium", "Semibold" },
    lighter = { Regular = "Light", Medium = "Regular", Semibold = "Medium" },
    bold   = "Medium",
    medium = "Regular",
    size   = 12.5,
    battery = 10, -- the level inside the battery glyph
  },

}

-- Islands hang `gap` from the top and end flush with the bar (the notch
-- strip): 32 - gap tall. Inner pills are concentric (inset 3).
-- Corner radius: one number for islands, menu and tooltip, set with the slider
-- in the right-click menu (lib/theme.lua keeps it), from 0 to the built-in
-- panel's own radius (`screen_corner`). Each shape takes min(radius, its
-- height / 2) (the helper daemon derives them): the island caps at a capsule
-- (13), the menu (64pt) at ~21. Default h / (2 * 1.528): the largest radius
-- at which Apple's continuous corner still fits the island unclamped.
do
  local g = M.bar.gap
  local h = M.bar.height - g
  M.bar.margin = g
  M.corner = { default = math.floor(h / (2 * 1.528) * 4 + 0.5) / 4, max = M.screen_corner }
  M.island = { height = h, gap = g, stroke = 1 }
  M.pill = { height = h - 6, inset = 3 }
end

-- A display whose menu bar is lower than the bar gets a shorter strip (the
-- auto-hidden menu bar must cover the islands when it slides in). Its islands
-- are the same islands scaled down as a whole (`scale`); the gaps between
-- islands stay `gap` on screen.
function M.strip(strip)
  local g = M.bar.gap
  local h = strip - g
  return {
    strip = strip,
    scale = h / M.island.height,
    island = M.island,
    pill = M.pill,
  }
end

-- Strip height on a display with a menu bar `menu_bar` pt tall (0 = unknown).
function M.strip_height(menu_bar)
  if menu_bar and menu_bar > 0 then return math.min(M.bar.height, menu_bar) end
  return M.bar.height
end

return M
