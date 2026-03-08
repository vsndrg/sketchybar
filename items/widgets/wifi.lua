local icons    = require("icons")
local colors   = require("colors")
local settings = require("settings")

sbar.exec("killall network_load >/dev/null; $CONFIG_DIR/helpers/event_providers/network_load/bin/network_load en0 network_update 5.0")

local popup_width = 250

-- Иконка wifi (добавляется первой → крайняя правая в пилюле)
local wifi = sbar.add("item", "widgets.wifi.icon", {
  position      = "right",
  padding_left  = 0,
  padding_right = 2,
  label = { drawing = false },
  icon = {
    string        = icons.wifi.connected,
    color         = colors.white,
    padding_left  = 6,
    padding_right = 6,
    y_offset      = 1,
    font = {
      family = settings.font.text,
      style  = settings.font.style_map["Regular"],
      size   = 13.0,
    },
  },
  background = { drawing = false },
})

-- Upload (добавляется второй → левее иконки)
local wifi_up = sbar.add("item", "widgets.wifi1", {
  position      = "right",
  padding_left  = 0,
  padding_right = 0,
  icon = {
    string        = icons.wifi.upload,
    color         = colors.grey,
    padding_left  = 6,
    padding_right = 2,
    font = {
      family = settings.font.text,
      style  = settings.font.style_map["Regular"],
      size   = 8.0,
    },
  },
  label = {
    string        = "??? Bps",
    color         = colors.grey,
    padding_right = 4,
    font = {
      family = settings.font.numbers,
      style  = settings.font.style_map["Regular"],
      size   = 8.0,
    },
  },
  background = { drawing = false },
})

-- Download (добавляется третьей → крайняя левая)
local wifi_down = sbar.add("item", "widgets.wifi2", {
  position      = "right",
  padding_left  = 0,
  padding_right = 0,
  icon = {
    string        = icons.wifi.download,
    color         = colors.grey,
    padding_left  = 6,
    padding_right = 2,
    font = {
      family = settings.font.text,
      style  = settings.font.style_map["Regular"],
      size   = 8.0,
    },
  },
  label = {
    string        = "??? Bps",
    color         = colors.grey,
    padding_right = 4,
    font = {
      family = settings.font.numbers,
      style  = settings.font.style_map["Regular"],
      size   = 8.0,
    },
  },
  background = { drawing = false },
})

-- Общая пилюля
local wifi_bracket = sbar.add("bracket", "widgets.wifi.bracket", {
  wifi_down.name,
  wifi_up.name,
  wifi.name,
}, {
  background = {
    height        = 22,
    corner_radius = 6,
    color         = colors.bg1,
    border_width  = 0,
  },
  popup = { align = "center", height = 30 },
})

sbar.add("item", "widgets.wifi.padding", {
  position = "right", width = 4,
  background = { drawing = false }, label = { drawing = false }, icon = { drawing = false },
})

-- Popup items
local ssid = sbar.add("item", {
  position = "popup." .. wifi_bracket.name,
  icon     = {
    string = icons.wifi.router,
    font   = { style = settings.font.style_map["Bold"] },
  },
  width    = popup_width,
  align    = "center",
  label    = {
    font      = { size = 14, style = settings.font.style_map["Bold"] },
    max_chars = 18,
    string    = "Wi-Fi",
  },
  background = { height = 1, color = colors.with_alpha(colors.grey, 0.3), y_offset = -15 },
})

local function make_popup_row(icon_str)
  return sbar.add("item", {
    position = "popup." .. wifi_bracket.name,
    icon     = { align = "left",  string = icon_str, width = popup_width / 2 },
    label    = { align = "right", string = "…",      width = popup_width / 2, max_chars = 20 },
  })
end

local hostname = make_popup_row("Hostname:")
local ip       = make_popup_row("IP:")
local mask     = make_popup_row("Subnet:")
local router   = make_popup_row("Router:")

wifi_up:subscribe("network_update", function(env)
  local up_color   = (env.upload   == "000 Bps") and colors.grey or colors.red
  local down_color = (env.download == "000 Bps") and colors.grey or 0xff7eb8ff
  wifi_up:set({
    icon  = { color = up_color },
    label = { string = env.upload,   color = up_color },
  })
  wifi_down:set({
    icon  = { color = down_color },
    label = { string = env.download, color = down_color },
  })
end)

wifi:subscribe({ "wifi_change", "system_woke" }, function(_)
  sbar.exec("ipconfig getifaddr en0", function(result)
    local connected = result ~= ""
    wifi:set({
      icon = {
        string = connected and icons.wifi.connected or icons.wifi.disconnected,
        color  = connected and colors.white or colors.red,
      },
    })
  end)
end)

local function hide_details()
  wifi_bracket:set({ popup = { drawing = false } })
end

local function toggle_details()
  if wifi_bracket:query().popup.drawing == "off" then
    -- Close other popups directly
    sbar.set("widgets.volume.bracket", { popup = { drawing = false } })
    sbar.set("widgets.battery",        { popup = { drawing = false } })
    wifi_bracket:set({ popup = { drawing = true } })
    sbar.exec("networksetup -getcomputername",                                         function(r) hostname:set({ label = r }) end)
    sbar.exec("ipconfig getifaddr en0",                                                function(r) ip:set({ label = r }) end)
    sbar.exec("ipconfig getsummary en0 | awk -F ' SSID : ' '/ SSID : / {print $2}'", function(r)
      local name = r:gsub("^%s+", ""):gsub("%s+$", "")
      if name == "" or name == "<redacted>" then
        sbar.exec("networksetup -getairportnetwork en0 | sed 's/Current Wi-Fi Network: //'", function(r2)
          local name2 = r2:gsub("^%s+", ""):gsub("%s+$", "")
          if name2 == "" or name2:find("not associated") then
            ssid:set({ label = "Wi-Fi" })
          else
            ssid:set({ label = name2 })
          end
        end)
      else
        ssid:set({ label = name })
      end
    end)
    sbar.exec("networksetup -getinfo Wi-Fi | awk -F 'Subnet mask: ' '/^Subnet mask: / {print $2}'", function(r) mask:set({ label = r }) end)
    sbar.exec("networksetup -getinfo Wi-Fi | awk -F 'Router: ' '/^Router: / {print $2}'",           function(r) router:set({ label = r }) end)
  else
    hide_details()
  end
end

local function copy_to_clipboard(env)
  local label = sbar.query(env.NAME).label.value
  sbar.exec('echo "' .. label .. '" | pbcopy')
  sbar.set(env.NAME, { label = { string = icons.clipboard, align = "center" } })
  sbar.delay(1, function()
    sbar.set(env.NAME, { label = { string = label, align = "right" } })
  end)
end

wifi_up:subscribe("mouse.clicked",    toggle_details)
wifi_down:subscribe("mouse.clicked",  toggle_details)
wifi:subscribe("mouse.clicked",       toggle_details)
wifi:subscribe("mouse.exited.global", hide_details)

ssid:subscribe("mouse.clicked",     copy_to_clipboard)
hostname:subscribe("mouse.clicked", copy_to_clipboard)
ip:subscribe("mouse.clicked",       copy_to_clipboard)
mask:subscribe("mouse.clicked",     copy_to_clipboard)
router:subscribe("mouse.clicked",   copy_to_clipboard)
