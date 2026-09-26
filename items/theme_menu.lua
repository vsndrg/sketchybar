-- Theme menu: accent (Auto · macOS accent swatches · Custom) over text weight.
-- A right click anywhere on the bar opens it: the helper daemon shows it as its
-- own window on the clicked display (a sketchybar popup only appears on the
-- display with the focused window). This renders it per strip height and
-- lists it in ~/.local/state/sketchybar/menu; the daemon highlights the entry
-- under the cursor (palette.hover over the image), fires
-- `menu_select ID=<entry>` on a click and keeps the menu open, so the next
-- render shows the new selection in place.
local config = require("config")
local theme = require("lib.theme")
local render = require("lib.render")
local color = require("lib.color")
local screens = require("lib.displays")

sbar.add("event", "menu_select")
sbar.add("event", "wallpaper_change")
sbar.add("event", "accent_preview")

local path = config.state .. "/menu"

-- A row is a 24pt pill padded to config.popup.height; pills are concentric
-- with the menu's corners.
local ROW_H, ROW_GAP, SIDE = 24, 5, 6
local PAD = (config.popup.height - ROW_H) / 2
local SWATCH, SWATCH_W, MARK = 16, 24, 5
local widths = { auto = 50, custom = 62, sep = 6 }
local INNER = widths.auto + widths.custom + 2 * widths.sep + #theme.presets * SWATCH_W
local W = INNER + 2 * SIDE
local H = 2 * PAD + 2 * ROW_H + ROW_GAP
local SHADOW = 26 -- margin for the shadow drawn around the menu (helper layoutMenu)

local function preset_index(c)
  for i, p in ipairs(theme.presets) do
    if p == c then return i end
  end
end

-- Entries in pt from the menu's top-left; ids are what `menu_select` carries.
local function entries(p)
  local font = config.font
  local selected = theme.mode == "auto" and "auto"
    or (preset_index(theme.custom) and ("swatch." .. preset_index(theme.custom)) or "custom")
  local list = {}
  local function text(id, x, y, w, str, style)
    local on = selected == id or id == "weight." .. theme.weight
    list[#list + 1] = { id = id, type = "text", x = x, y = y, w = w, h = ROW_H, text = str, font = font.text,
      style = style, size = font.size, color = color.hex(on and p.text or p.muted), selected = on or nil }
  end

  local x, y = SIDE, PAD
  text("auto", x, y, widths.auto, "Auto", font.medium)
  x = x + widths.auto + widths.sep
  for i, c in ipairs(theme.presets) do
    local id = "swatch." .. i
    list[#list + 1] = { id = id, type = "swatch", x = x, y = y, w = SWATCH_W, h = ROW_H, d = SWATCH, mark = MARK,
      color = color.hex(c), ring = "0x26ffffff", selected = selected == id or nil }
    x = x + SWATCH_W
  end
  text("custom", x + widths.sep, y, widths.custom, "Custom", font.medium)

  -- each weight in its own face, as a segmented control across the menu;
  -- segments apart like the first row's pills (a pill never touches the next)
  y = y + ROW_H + ROW_GAP
  local n = #font.weights
  local seg = (INNER - (n - 1) * widths.sep) / n
  for i, w in ipairs(font.weights) do
    text("weight." .. w, SIDE + (i - 1) * (seg + widths.sep), y, seg, w, w)
  end
  return list
end

local written
local function write(lines)
  local body = table.concat(lines, "\n") .. "\n"
  if body == written then return end
  local f = io.open(path .. ".tmp", "w")
  if not f then return end
  f:write(body)
  f:close()
  os.rename(path .. ".tmp", path)
  written = body
end

local palette = theme.palette()
local seq = 0

local function paint()
  seq = seq + 1
  local my = seq
  local list = entries(palette)
  local strips, geos = {}, {}
  for _, d in ipairs(screens.list) do
    if not geos[d.geo.strip] then
      geos[d.geo.strip] = d.geo
      strips[#strips + 1] = d.geo.strip
    end
  end
  local jobs = {}
  for i, strip in ipairs(strips) do
    jobs[i] = render.menu({
      w = W, h = H, m = SHADOW, r = config.popup.radius,
      fill = color.hex(palette.menu), stroke = "0x24ffffff", sw = 1,
      pill = color.hex(palette.pill), pill_r = config.popup.radius - PAD,
      entries = list,
    }, geos[strip])
  end
  render.run(jobs, function(m)
    if my ~= seq then return end
    local out, paths = {}, {}
    for i, strip in ipairs(strips) do
      out[strip] = m[i].out
      paths[i] = m[i].out
    end
    render.pin("menu", paths)
    -- the menu's right edge at the islands', its top config.popup.offset below
    -- them (the strip's bottom); the image is larger by the shadow margin.
    -- Hit rects scaled with the image on a shorter strip.
    local lines = {}
    for _, d in ipairs(screens.list) do
      local s = d.geo.scale
      local m = SHADOW * s
      lines[#lines + 1] = string.format("menu %d %g %g %g %s %s", d.did, config.bar.margin - m,
        d.geo.strip + config.popup.offset - m, (config.popup.radius - PAD) * s, color.hex(palette.hover),
        out[d.geo.strip])
      for _, e in ipairs(list) do
        lines[#lines + 1] = string.format("hit %d %s %g %g %g %g", d.did, e.id,
          m + e.x * s, m + e.y * s, m + (e.x + e.w) * s, m + (e.y + e.h) * s)
      end
    end
    write(lines)
  end)
end

-- Events -----------------------------------------------------------------------

local watcher = sbar.add("item", "theme.events", { drawing = false, updates = true })

watcher:subscribe("menu_select", function(env)
  local id = env.ID or ""
  local swatch = tonumber(id:match("^swatch%.(%d+)$"))
  local weight = id:match("^weight%.(%a+)$")
  if id == "auto" then
    theme.set_auto()
  elseif swatch and theme.presets[swatch] then
    theme.set_custom(theme.presets[swatch])
  elseif weight then
    theme.set_weight(weight)
  elseif id == "custom" then
    -- the daemon has closed the menu; the color panel previews live
    local cmd = string.format("'%s' pick %s", config.helper, color.hex(theme.accent()))
    sbar.exec(cmd, function(out)
      local c = type(out) == "string" and color.parse(out:match("0x%x+")) or nil
      if c then theme.set_custom(c) else theme.set_preview(nil) end
    end)
  end
end)

watcher:subscribe("wallpaper_change", function(env)
  theme.set_wallpaper(color.parse(env.ACCENT))
end)
watcher:subscribe("accent_preview", function(env)
  local c = color.parse(env.ACCENT)
  if c then theme.set_preview(c) end
end)

screens.on_change(paint)

theme.on(function(p)
  palette = p
  paint()
end)
