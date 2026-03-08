local settings = require("settings")
local colors   = require("colors")

sbar.add("item", { position = "right", width = 4 })

local cal = sbar.add("item", {
  position = "right",
  icon = {
    color         = 0xffcfcae8,
    padding_left  = 8,
    padding_right = 8,
    y_offset      = 0,
    font = {
      family = settings.font.text,
      style  = settings.font.style_map["Semibold"],
      size   = 12.0,
    },
  },
  label = {
    color         = colors.white,
    padding_right = 8,
    padding_left  = 0,
    y_offset      = 0,
    font = {
      family = settings.font.numbers,
      style  = settings.font.style_map["Regular"],
      size   = 12.0,
    },
  },
  padding_left  = 2,
  padding_right = 2,
  update_freq   = 30,
  background = {
    height        = 22,
    corner_radius = 6,
    color         = colors.bg1,
    border_width  = 0,
  },
  click_script = "open -a 'Calendar'",
})

sbar.add("item", { position = "right", width = 4 })

cal:subscribe({ "forced", "routine", "system_woke" }, function(env)
  cal:set({
    icon  = { string = os.date("%a %d %b") },
    label = { string = os.date("%H:%M") },
  })
end)
