local icons    = require("icons")
local colors   = require("colors")
local settings = require("settings")

local battery = sbar.add("item", "widgets.battery", {
  position = "right",
  padding_left  = 2,
  padding_right = 2,
  icon = {
    font = {
      family = settings.font.text,
      style  = settings.font.style_map["Regular"],
      size   = 15.0,
    },
    color        = colors.green,
    padding_left  = 7,
    padding_right = 3,
  },
  label = {
    font = {
      family = settings.font.numbers,
      style  = settings.font.style_map["Regular"],
      size   = 11.0,
    },
    color         = colors.white,
    padding_right = 7,
  },
  background = {
    height        = 22,
    corner_radius = 6,
    color         = colors.bg1,
    border_width  = 0,
  },
  update_freq = 180,
  popup       = { align = "center" },
})

local remaining_time = sbar.add("item", {
  position = "popup." .. battery.name,
  icon     = { string = "Time remaining:", width = 100, align = "left" },
  label    = { string = "??:??h",          width = 100, align = "right" },
})

battery:subscribe({ "routine", "power_source_change", "system_woke" }, function()
  sbar.exec("pmset -g batt", function(batt_info)
    local icon  = "!"
    local label = "?"
    local found, _, charge = batt_info:find("(%d+)%%")
    if found then
      charge = tonumber(charge)
      label  = charge .. "%"
    end

    local color    = colors.green
    local charging = batt_info:find("AC Power")

    if charging then
      icon = icons.battery.charging
    elseif found and charge > 80 then
      icon = icons.battery._100
    elseif found and charge > 60 then
      icon = icons.battery._75
      color = colors.green
    elseif found and charge > 40 then
      icon = icons.battery._50
      color = colors.yellow
    elseif found and charge > 20 then
      icon = icons.battery._25
      color = colors.orange
    else
      icon  = icons.battery._0
      color = colors.red
    end

    battery:set({
      icon  = { string = icon, color = color },
      label = { string = (found and charge < 10 and "0" or "") .. label },
    })
  end)
end)

battery:subscribe("mouse.clicked", function(_)
  local drawing = battery:query().popup.drawing
  if drawing == "off" then
    -- Close other popups directly
    sbar.set("widgets.volume.bracket", { popup = { drawing = false } })
    sbar.set("widgets.wifi.bracket",   { popup = { drawing = false } })
    battery:set({ popup = { drawing = true } })
    sbar.exec("pmset -g batt", function(info)
      local found, _, rem = info:find(" (%d+:%d+) remaining")
      remaining_time:set({ label = found and rem .. "h" or "No estimate" })
    end)
  else
    battery:set({ popup = { drawing = false } })
  end
end)

sbar.add("item", "widgets.battery.padding", {
  position = "right", width = 4,
  background = { drawing = false }, label = { drawing = false }, icon = { drawing = false },
})
