local icons    = require("icons")
local colors   = require("colors")
local settings = require("settings")

sbar.exec("killall cpu_load >/dev/null; $CONFIG_DIR/helpers/event_providers/cpu_load/bin/cpu_load cpu_update 5.0")

local cpu = sbar.add("graph", "widgets.cpu", 42, {
  position = "right",
  padding_left  = 2,
  padding_right = 2,
  graph = {
    color            = 0xff7eb8ff,
    fill_color       = colors.with_alpha(0xff7eb8ff, 0.5),
  },
  background = {
    height        = 22,
    corner_radius = 6,
    color         = colors.bg1,
    border_color  = colors.transparent,
    border_width  = 0,
    drawing       = true,
  },
  icon = {
    string        = icons.cpu,
    color         = colors.grey,
    padding_left  = 7,
    padding_right = 4,
    font = {
      family = settings.font.text,
      style  = settings.font.style_map["Regular"],
      size   = 13.0,
    },
  },
  label = {
    string        = "??%",
    font = {
      family = settings.font.numbers,
      style  = settings.font.style_map["Regular"],
      size   = 9.0,
    },
    color         = colors.grey,
    align         = "right",
    padding_right = 7,
    width         = 0,
    y_offset      = 4,
  },
})

cpu:subscribe("cpu_update", function(env)
  local load  = tonumber(env.total_load)
  local color = 0xff7eb8ff
  if     load > 80 then color = colors.red
  elseif load > 60 then color = colors.orange
  elseif load > 30 then color = colors.yellow
  end
  cpu:push({ load / 100.0 })
  cpu:set({
    graph = { color = color },
    label = { string = env.total_load .. "%" },
  })
end)

cpu:subscribe("mouse.clicked", function(_)
  sbar.exec("open -a 'Activity Monitor'")
end)

sbar.add("item", "widgets.cpu.padding", {
  position = "right", width = 4,
  background = { drawing = false }, label = { drawing = false }, icon = { drawing = false },
})
