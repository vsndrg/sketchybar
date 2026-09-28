-- Text weight (picked in the right-click menu) and the style the daemon draws
-- the bar with. The bar is Liquid Glass with system colors: no accent.
local config = require("config")
local sh = require("lib.sh")
local bar = require("lib.bar")

local M = {
  weight = config.font.bold,
}

local state_file = config.state .. "/theme"
sh.run("mkdir -p '" .. config.state .. "'")

local function load()
  local f = io.open(state_file, "r")
  if not f then return end
  for line in f:lines() do
    local k, v = line:match("^(%w+)=(.+)$")
    if k == "weight" and config.font.lighter[v] then M.weight = v end
  end
  f:close()
end

local function save()
  local f = io.open(state_file, "w")
  if not f then return end
  f:write("weight=", M.weight, "\n")
  f:close()
end

-- Primary text (workspace digits, date and time, layout, battery level) in
-- `bold`, secondary (tooltip) one step lighter in `medium`.
local function apply_weight()
  config.font.bold = M.weight
  config.font.medium = config.font.lighter[M.weight]
end

function M.apply()
  local island, pill, popup, font = config.island, config.pill, config.popup, config.font
  bar.set("style", {
    gap = config.bar.gap, bar = config.bar.height, radius = island.radius,
    pill_h = pill.height, pill_r = pill.radius, inset = pill.inset,
    family = font.text, size = font.size, battery = font.battery,
    primary = font.bold, secondary = font.medium, weights = font.weights,
    popup_h = popup.height, popup_r = popup.radius, popup_offset = popup.offset,
  })
end

function M.set_weight(w)
  if not config.font.lighter[w] or w == M.weight then return end
  M.weight = w
  apply_weight()
  save()
  M.apply()
end

load()
apply_weight()
return M
