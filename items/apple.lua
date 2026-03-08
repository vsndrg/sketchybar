local colors   = require("colors")
local icons    = require("icons")
local settings = require("settings")

sbar.add("item", { width = 4 })

local apple = sbar.add("item", "apple.icon", {
  icon = {
    string        = icons.apple,
    font          = {
      family = settings.font.text,
      style  = settings.font.style_map["Regular"],
      size   = 14.0,
    },
    color         = colors.white,
    padding_left  = 8,
    padding_right = 8,
    y_offset      = 1,
  },
  label      = { drawing = false },
  background = {
    height        = 24,
    corner_radius = 8,
    color         = colors.bg1,
    border_width  = 0,
  },
  padding_left  = 2,
  padding_right = 2,
  click_script  = "$CONFIG_DIR/helpers/menus/bin/menus -s 0",
})

apple:subscribe("mouse.entered", function(_)
  apple:set({
    icon = {
      color = colors.black,
    },
    background = {
      color        = colors.accent,
      border_width = 0,
    },
  })
end)

apple:subscribe("mouse.exited", function(_)
  apple:set({
    icon = {
      color = colors.white,
    },
    background = {
      color        = colors.bg1,
      border_width = 0,
    },
  })
end)

sbar.add("item", { width = 4 })
