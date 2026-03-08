local colors   = require("colors")
local settings = require("settings")

local front_app = sbar.add("item", "front_app", {
  display = "active",
  icon    = { drawing = false },
  label   = {
    color = colors.with_alpha(colors.white, 0.75),
    font  = {
      family = settings.font.text,
      style  = settings.font.style_map["Semibold"],
      size   = 12.0,
    },
  },
  updates = true,
})

front_app:subscribe("front_app_switched", function(env)
  front_app:set({ label = { string = env.INFO } })
end)

front_app:subscribe("mouse.clicked", function(_)
  sbar.trigger("swap_menus_and_spaces")
end)
