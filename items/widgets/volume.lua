local colors   = require("colors")
local icons    = require("icons")
local settings = require("settings")

local popup_width = 250

-- Иконка громкости (добавляется первой → правее в пилюле)
local volume_icon = sbar.add("item", "widgets.volume2", {
  position      = "right",
  padding_left  = 0,
  padding_right = 2,
  icon = {
    string        = icons.volume._100,
    color         = colors.white,
    padding_left  = 6,
    padding_right = 6,
    font = {
      family = settings.font.text,
      style  = settings.font.style_map["Regular"],
      size   = 13.0,
    },
  },
  label      = { drawing = false },
  background = { drawing = false, height = 22 },
})

-- Процент громкости (добавляется второй → левее в пилюле)
local volume_percent = sbar.add("item", "widgets.volume1", {
  position      = "right",
  padding_left  = 2,
  padding_right = 0,
  icon          = { drawing = false },
  label = {
    string        = "??%",
    color         = colors.white,
    padding_left  = 6,
    padding_right = 4,
    font = {
      family = settings.font.numbers,
      style  = settings.font.style_map["Regular"],
      size   = 11.0,
    },
  },
  background = { drawing = false, height = 22 },
})

local volume_bracket = sbar.add("bracket", "widgets.volume.bracket", {
  volume_percent.name,
  volume_icon.name,
}, {
  background = {
    height        = 22,
    corner_radius = 6,
    color         = colors.bg1,
    border_width  = 0,
  },
  popup = { align = "center" },
})

sbar.add("item", "widgets.volume.padding", {
  position = "right", width = 4,
  background = { drawing = false }, label = { drawing = false }, icon = { drawing = false },
})

local volume_slider = sbar.add("slider", popup_width, {
  position = "popup." .. volume_bracket.name,
  slider = {
    highlight_color = colors.accent,
    background = {
      height        = 4,
      corner_radius = 2,
      color         = colors.bg2,
    },
    knob = {
      string   = "●",
      drawing  = true,
      y_offset = 1,
      font     = {
        family = settings.font.text,
        style  = settings.font.style_map["Bold"],
        size   = 12.0,
      },
    },
  },
  background    = { drawing = false },
  click_script  = 'osascript -e "set volume output volume $PERCENTAGE"',
})

volume_percent:subscribe("volume_change", function(env)
  local volume = tonumber(env.INFO)
  local icon
  if volume > 60 then     icon = icons.volume._100
  elseif volume > 30 then icon = icons.volume._66
  elseif volume > 10 then icon = icons.volume._33
  elseif volume > 0  then icon = icons.volume._10
  else                    icon = icons.volume._0
  end
  volume_icon:set({ icon = { string = icon } })
  volume_percent:set({ label = (volume < 10 and "0" or "") .. volume .. "%" })
  volume_slider:set({ slider = { percentage = volume } })
end)

local function volume_collapse()
  if volume_bracket:query().popup.drawing ~= "on" then return end
  volume_bracket:set({ popup = { drawing = false } })
  sbar.remove('/volume.device\\.*/')
end

local function volume_toggle(env)
  if env.BUTTON == "right" then
    sbar.exec("open /System/Library/PreferencePanes/Sound.prefpane")
    return
  end
  if volume_bracket:query().popup.drawing == "off" then
    -- Close other popups directly
    sbar.set("widgets.wifi.bracket",  { popup = { drawing = false } })
    sbar.set("widgets.battery",       { popup = { drawing = false } })
    volume_bracket:set({ popup = { drawing = true } })
    sbar.exec("SwitchAudioSource -t output -c", function(current)
      current = current:sub(1, -2)
      sbar.exec("SwitchAudioSource -a -t output", function(all)
        local counter = 0
        for device in string.gmatch(all, '[^\r\n]+') do
          sbar.add("item", "volume.device." .. counter, {
            position = "popup." .. volume_bracket.name,
            width    = popup_width,
            align    = "center",
            label    = {
              string = device,
              color  = (current == device) and colors.accent or colors.grey,
            },
            click_script = 'SwitchAudioSource -s "' .. device .. '" && sketchybar --set /volume.device\\.*/ label.color=' .. colors.grey .. ' --set $NAME label.color=' .. colors.accent,
          })
          counter = counter + 1
        end
      end)
    end)
  else
    volume_collapse()
  end
end

local function volume_scroll(env)
  local delta = env.INFO.delta
  if not (env.INFO.modifier == "ctrl") then delta = delta * 10.0 end
  sbar.exec('osascript -e "set volume output volume (output volume of (get volume settings) + ' .. delta .. ')"')
end

volume_icon:subscribe("mouse.clicked",  volume_toggle)
volume_icon:subscribe("mouse.scrolled", volume_scroll)
volume_percent:subscribe("mouse.clicked",       volume_toggle)
volume_percent:subscribe("mouse.exited.global", volume_collapse)
volume_percent:subscribe("mouse.scrolled",      volume_scroll)
