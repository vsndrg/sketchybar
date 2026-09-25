-- Theme popup: Auto (wallpaper) · macOS accent swatches · Custom (native picker).
-- Opened by right click on the bar or `sketchybar --trigger theme_menu`.
local config = require("config")
local theme = require("lib.theme")
local shape = require("lib.shape")
local frame = require("lib.frame")
local color = require("lib.color")

return function(anchor)
  local font = config.font
  local P = "popup." .. anchor.name

  local SWATCH, SWATCH_W = 16, 24
  local TEXT_H = 24
  local widths = { auto = 50, custom = 62, sep = 6 }

  sbar.add("event", "theme_menu")
  sbar.add("event", "wallpaper_change")
  sbar.add("event", "accent_preview")

  local function text_item(name, str, width)
    return sbar.add("item", name, {
      position = P,
      width = width,
      padding_left = 0,
      padding_right = 0,
      icon = { drawing = false },
      label = {
        string = str,
        width = width,
        align = "center",
        padding_left = 0,
        padding_right = 0,
        font = { family = font.text, style = font.medium, size = font.size },
        y_offset = font.y_offset,
      },
      background = { drawing = true, color = 0, image = { drawing = false, scale = config.image_scale } },
    })
  end

  local function spacer(name)
    return sbar.add("item", name, { position = P, width = widths.sep, padding_left = 0, padding_right = 0 })
  end

  local auto = text_item("theme.auto", "Auto", widths.auto)
  spacer("theme.sep.1")

  local swatches = {}
  for i, c in ipairs(theme.presets) do
    swatches[i] = sbar.add("item", "theme.swatch." .. i, {
      position = P,
      width = SWATCH_W,
      padding_left = 0,
      padding_right = 0,
      icon = { drawing = false },
      label = {
        string = "●",
        width = SWATCH_W,
        align = "center",
        padding_left = 0,
        padding_right = 0,
        y_offset = 1,
        font = { family = font.text, style = font.bold, size = 7 },
        color = 0xffffffff,
        drawing = false,
      },
      background = {
        drawing = true,
        color = 0,
        image = { drawing = true, scale = config.image_scale, padding_left = (SWATCH_W - SWATCH) / 2 },
      },
    })
    local dot = shape.squircle(SWATCH, SWATCH, SWATCH / 2, c, 0x26ffffff, 1)
    frame.commit("swatch." .. i, { dot }, function()
      swatches[i]:set({ background = { image = { string = dot.path } } })
    end)
  end

  spacer("theme.sep.2")
  local custom = text_item("theme.custom", "Custom", widths.custom)

  local total = widths.auto + widths.custom + 2 * widths.sep + #swatches * SWATCH_W
  local popup_w = total + 12

  -- Selection ---------------------------------------------------------------------

  local function preset_index(c)
    for i, p in ipairs(theme.presets) do
      if p == c then return i end
    end
  end

  local function paint(p)
    local selected = theme.mode == "auto" and "auto" or (preset_index(theme.custom) or "custom")
    local pill_r = config.popup.radius - (config.popup.height - TEXT_H) / 2
    local bg = shape.squircle(popup_w, config.popup.height, config.popup.radius, p.popup, 0x1fffffff, 1)
    local pill = shape.squircle(widths[selected] and widths[selected] or 1, TEXT_H, pill_r,
      p.pill)
    local assets = { bg }
    if widths[selected] then table.insert(assets, pill) end

    frame.commit("theme_menu", assets, function()
      anchor:set({ popup = { background = {
        drawing = true, color = 0, border_width = 0, corner_radius = 0,
        image = { string = bg.path, drawing = true, scale = config.image_scale },
      } } })
      for key, item in pairs({ auto = auto, custom = custom }) do
        local on = selected == key
        item:set({
          label = { color = on and p.text or p.muted },
          background = { image = on and { string = pill.path, drawing = true } or { drawing = false } },
        })
      end
      for i, s in ipairs(swatches) do
        s:set({ label = { drawing = selected == i } })
      end
    end)
  end

  -- Open / close -------------------------------------------------------------------

  local open = false
  local token = 0
  local function show(on)
    open = on
    token = token + 1
    anchor:set({ popup = { drawing = on } })
    if on then
      -- no mouse.exited.global (event floods can deadlock the bar); close on
      -- selection, toggle, focus change, or after a short idle instead
      local my = token
      sbar.delay(6, function() if open and token == my then show(false) end end)
    end
  end

  local watcher = sbar.add("item", "theme.events", { drawing = false, updates = true })

  watcher:subscribe("theme_menu", function() show(not open) end)
  watcher:subscribe({ "aerospace_workspace_change", "aerospace_focus_change", "front_app_switched" }, function()
    if open then show(false) end
  end)

  watcher:subscribe("wallpaper_change", function(env)
    theme.set_wallpaper(color.parse(env.ACCENT))
  end)
  watcher:subscribe("accent_preview", function(env)
    local c = color.parse(env.ACCENT)
    if c then theme.set_preview(c) end
  end)

  auto:subscribe("mouse.clicked", function()
    theme.set_auto()
    show(false)
  end)

  for i, s in ipairs(swatches) do
    s:subscribe("mouse.clicked", function()
      theme.set_custom(theme.presets[i])
      show(false)
    end)
  end

  custom:subscribe("mouse.clicked", function()
    show(false)
    local cmd = string.format("'%s' pick %s", config.helper, color.hex(theme.accent()))
    sbar.exec(cmd, function(out)
      local c = type(out) == "string" and color.parse(out:match("0x%x+")) or nil
      if c then theme.set_custom(c) else theme.set_preview(nil) end
    end)
  end)

  theme.on(paint)
end
