local colors = require("colors")

sbar.bar({
  height        = 33,
  color         = colors.bar.bg,
  border_color  = colors.bar.border,
  border_width  = 0,
  shadow        = false,
  padding_right = 8,
  padding_left  = 8,
  blur_radius   = 30,
  topmost       = "off",
})
