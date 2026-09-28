-- Theme menu: text weight, corner radius. A right click anywhere on the bar
-- opens it (the helper daemon's own glass window on the clicked display); a
-- pick fires `menu_select ID=weight.<Weight>`, releasing the radius slider
-- `ID=corner.<radius>`; the menu stays open, showing the new selection once
-- the style is republished.
local theme = require("lib.theme")

sbar.add("event", "menu_select")

local watcher = sbar.add("item", "theme.events", { drawing = false, updates = true })

watcher:subscribe("menu_select", function(env)
  local weight = (env.ID or ""):match("^weight%.(%a+)$")
  if weight then theme.set_weight(weight) end
  local corner = (env.ID or ""):match("^corner%.([%d%.]+)$")
  if corner then theme.set_corner(corner) end
end)
