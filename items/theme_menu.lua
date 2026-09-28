-- Theme menu: text weight. A right click anywhere on the bar opens it (the
-- helper daemon's own glass window on the clicked display); a pick fires
-- `menu_select ID=weight.<Weight>` and the menu stays open, showing the new
-- selection once the style is republished.
local theme = require("lib.theme")

sbar.add("event", "menu_select")

local watcher = sbar.add("item", "theme.events", { drawing = false, updates = true })

watcher:subscribe("menu_select", function(env)
  local weight = (env.ID or ""):match("^weight%.(%a+)$")
  if weight then theme.set_weight(weight) end
end)
