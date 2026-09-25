-- Right side, right to left: clock │ battery │ layout — three islands drawn
-- into ONE fixed-width item (notch → edge), so any change (a minute ticking,
-- the date, a charging bolt) is a single content swap with nothing shifting.
-- One such item per display (islands as tall as that display's strip, see
-- config.strip); the content and horizontal layout are the same on all.
local config = require("config")
local theme = require("lib.theme")
local render = require("lib.render")
local color = require("lib.color")
local regions = require("lib.regions")
local screens = require("lib.displays")

local font = config.font
local WIDTH = config.side_width.right
-- The item is right-aligned on every display: positions are measured from
-- the right edge of the screen, which works on any display width. On a
-- display with a shorter strip the whole item is scaled (config.strip).
local function width_for(geo) return math.floor(WIDTH * geo.scale + 0.5) end
local palette = theme.palette()

sbar.add("event", "layout_change")

-- Zero-width anchor at the right edge; the theme menu hangs off it.
local anchor = sbar.add("item", "menu.anchor", {
  position = "right",
  width = 0,
  popup = { align = "right", horizontal = true, height = config.popup.height, y_offset = config.popup.offset },
})

-- global events: an invisible item that never goes away. The clock follows
-- `minute_change` from the helper daemon (fired right on the minute); the
-- routine polls the battery and is the clock's fallback.
sbar.add("event", "minute_change")
local events = sbar.add("item", "status", { drawing = false, updates = true, update_freq = 60 })

-- Battery tooltip: drawn by the helper daemon on the display under the cursor
-- (a sketchybar popup only shows on the display with the focused window).
-- Its canvas reaches from the bubble to the item's right edge, so the bubble
-- is centered under the battery; listed per display for the daemon.
local tips_path = config.state .. "/tooltips"
local tips_written

local function write_tips(lines)
  local text = table.concat(lines, "\n") .. "\n"
  if text == tips_written then return end
  local f = io.open(tips_path .. ".tmp", "w")
  if not f then return end
  f:write(text)
  f:close()
  os.rename(tips_path .. ".tmp", tips_path)
  tips_written = text
end

local clicked -- mouse.clicked handler, defined below
local by_did = {} -- did -> { item, geo }
local displays = {}

local function sync_displays()
  local seen, now = {}, {}
  for _, x in ipairs(screens.list) do
    local d = by_did[x.did]
    if not d then
      d = { did = x.did }
      d.item = sbar.add("item", "status." .. x.did, {
        position = "right",
        display = x.arr,
        width = width_for(x.geo),
        y_offset = x.geo.y_offset,
        icon = { drawing = false },
        label = { drawing = false },
        background = { drawing = true, color = 0, image = { drawing = true, scale = config.image_scale } },
      })
      d.item:subscribe("mouse.clicked", function(env) clicked(env) end)
      by_did[x.did] = d
    elseif d.arr ~= x.arr or d.geo.strip ~= x.geo.strip then
      d.item:set({ display = x.arr, width = width_for(x.geo), y_offset = x.geo.y_offset })
    end
    d.arr, d.mon, d.geo = x.arr, x.mon, x.geo
    seen[x.did] = true
    now[#now + 1] = d
  end
  for did, d in pairs(by_did) do
    if not seen[did] then
      sbar.remove(d.item.name)
      by_did[did] = nil
    end
  end
  displays = now
end

local state = {
  code = "EN",
  -- assume a battery until pmset says otherwise (no shift at startup on laptops)
  has_battery = true,
  level = 100, charge = 0, low = false, status = "",
}
-- strip -> name -> { r0, r1 }: island edges from the item's right edge, in the
-- bar's units (multiply by that strip's scale for points), from the last render
local islands = {}
local seq = 0

-- Wording and title case as in the macOS battery menu.
local function status_text(level, charge, remaining)
  if charge == 1 then
    return remaining and (remaining .. " Until Full") or "Charging"
  elseif charge == 2 then
    return level >= 100 and "Fully Charged" or "Not Charging"
  end
  return remaining and (remaining .. " Remaining") or "Calculating Time Remaining…"
end

local function text(str, style, c, extra)
  local t = { type = "text", text = str, font = font.text, style = style, size = font.size, color = color.hex(c) }
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end

local function write_regions()
  -- distances from the screen's right edge (see lib/regions.lua)
  local list = {}
  for _, d in ipairs(displays) do
    local b = islands[d.geo.strip] and islands[d.geo.strip].battery
    local s, m = d.geo.scale, config.bar.margin
    if b then list[#list + 1] = { "battery", "right", m + b.r0 * s, m + b.r1 * s, d.did } end
  end
  regions.set("status", list)
end

-- The row jobs (one per strip) showing time t.
local function rows_at(t, strips, geos)
  local rows = {}
  local d = os.date("%a ", t) .. tonumber(os.date("%d", t)) .. os.date(" %b", t)
  for i, strip in ipairs(strips) do
    local geo = geos[strip]
    local input = render.base("island", palette)
    input.pad_l, input.pad_r = 10, 10
    input.parts = { text(state.code, font.bold, palette.muted, { min_text = "RU", align = "center" }) }

    local battery = render.base("island", palette)
    battery.pad_l, battery.pad_r = 10, 10
    battery.parts = { { type = "battery", level = state.level, state = state.charge,
      color = color.hex(state.low and palette.red or palette.text) } }

    local clock = render.base("island", palette)
    clock.pad_l, clock.pad_r = 10, 10
    clock.parts = {
      text(d, font.medium, palette.muted),
      { type = "gap", w = 6 },
      -- widest digits reserve the width, so the island never changes minute to minute
      text(os.date("%H:%M", t), font.bold, palette.text, { min_text = "00:00", align = "right" }),
    }

    local parts = { input, clock }
    if state.has_battery then table.insert(parts, 2, battery) end
    -- drawn at the bar's size, shown scaled: the canvas fills the scaled item
    -- and the gap between islands stays config.island.gap on screen
    rows[i] = render.row({ canvas_w = width_for(geo) / geo.scale, align = "right",
                           gap = config.island.gap / geo.scale, islands = parts }, geo)
  end
  return rows
end

local function show()
  seq = seq + 1
  local my = seq

  -- one row (and tooltip) per distinct strip height
  local strips, geos = {}, {}
  for _, d in ipairs(displays) do
    if not geos[d.geo.strip] then
      geos[d.geo.strip] = d.geo
      strips[#strips + 1] = d.geo.strip
    end
  end
  if #strips == 0 then return end

  local names = { "input", "clock" }
  if state.has_battery then table.insert(names, 2, "battery") end
  local now = os.time()

  render.run(rows_at(now, strips, geos), function(m)
    if my ~= seq then return end
    islands = {}
    for i, strip in ipairs(strips) do
      local cw = width_for(geos[strip]) / geos[strip].scale
      islands[strip] = {}
      for k, name in ipairs(names) do
        local isl = m[i].islands[k]
        islands[strip][name] = { r0 = cw - isl.x1, r1 = cw - isl.x0 }
      end
    end
    local out = {}
    for i, strip in ipairs(strips) do out[strip] = m[i].out end
    sbar.begin_config()
    for _, x in ipairs(displays) do
      x.item:set({ background = { image = { string = out[x.geo.strip] } } })
    end
    sbar.end_config()
    write_regions()

    -- the next minute's image, so the minute change is a cached swap
    render.run(rows_at((now // 60 + 1) * 60, strips, geos))

    -- tooltip for the current battery state (rendered ahead of any hover)
    if not state.has_battery then return write_tips({}) end
    local jobs = {}
    for i, strip in ipairs(strips) do
      local b = islands[strip].battery
      local bubble = render.base("island", palette)
      bubble.fill = color.hex(palette.popup)
      bubble.pad_l, bubble.pad_r = 10, 10
      bubble.parts = { text(state.status, font.medium, palette.muted) }
      jobs[i] = render.row({ center_from_right = (b.r0 + b.r1) / 2, align = "left", islands = { bubble } },
        geos[strip])
    end
    render.run(jobs, function(tm)
      if my ~= seq then return end
      local by_strip, lines = {}, {}
      for i, strip in ipairs(strips) do by_strip[strip] = tm[i].out end
      for _, x in ipairs(displays) do
        -- "<region> <display> <right> <top> <png>": right edge at the item's,
        -- top config.popup.offset below the islands (the strip's bottom)
        lines[#lines + 1] = string.format("battery %d %g %g %s", x.did, config.bar.margin,
          x.geo.strip + config.popup.offset, by_strip[x.geo.strip])
      end
      write_tips(lines)
    end)
  end)
end

-- Data -------------------------------------------------------------------------

local last_minute
local function tick()
  local now = os.date("%Y%m%d%H%M")
  if now ~= last_minute then
    last_minute = now
    show()
  end
end

local function update_battery()
  sbar.exec("pmset -g batt", function(out)
    if type(out) ~= "string" then return end
    -- desktop Macs have no internal battery: drop the island entirely
    local has_battery = out:find("InternalBattery") ~= nil
    if not has_battery then
      if state.has_battery then
        state.has_battery = false
        show()
      end
      return
    end
    state.has_battery = true
    local ac = out:find("AC Power") ~= nil
    local level = tonumber(out:match("(%d+)%%")) or state.level
    local charging = out:find(";%s*charging") ~= nil or out:find("finishing charge") ~= nil
    local t = out:match("(%d+:%d+) remaining")
    state.level = level
    state.charge = charging and 1 or (ac and 2 or 0)
    state.low = level <= 20 and not ac
    state.status = status_text(level, state.charge, (t and t ~= "0:00") and t or nil)
    show()
  end)
end

-- Events -----------------------------------------------------------------------

events:subscribe("minute_change", tick)

local ticks = 0
events:subscribe("routine", function()
  ticks = ticks + 1
  tick()
  update_battery()
  if ticks % 10 == 0 then render.gc(30 * 60) end -- every 10 minutes
end)
events:subscribe({ "forced", "system_woke", "power_source_change" }, update_battery)

events:subscribe("layout_change", function(env)
  if env.LAYOUT and env.LAYOUT ~= "" and env.LAYOUT ~= state.code then
    state.code = env.LAYOUT
    show()
  end
end)

clicked = function(env)
  if env.BUTTON == "right" then
    sbar.exec("sketchybar --trigger theme_menu")
    return
  end
  -- "<x on the screen under the cursor> <that screen's width> <its display id>"
  sbar.exec("'" .. config.helper .. "' cursor", function(out)
    local x, w, did = tostring(out):match("^%s*(%-?%d+)%s+(%d+)%s*(%d*)")
    x, w = tonumber(x), tonumber(w)
    local d = by_did[tonumber(did)] or displays[1]
    if not x or not w or not d or not islands[d.geo.strip] then return end
    -- distance from the item's right edge, in the bar's units
    local r = (w - config.bar.margin - x) / d.geo.scale
    local function inside(name)
      local isl = islands[d.geo.strip][name]
      return isl and r > isl.r0 and r <= isl.r1
    end
    if inside("input") then
      sbar.exec("'" .. config.helper .. "' layout next")
    elseif inside("clock") then
      sbar.exec("open -a Calendar")
    end
  end)
end

-- Display set changes (Sidecar connect/disconnect)
screens.on_change(function()
  sync_displays()
  show()
end)

sync_displays()

theme.on(function(p)
  palette = p
  show()
end)

update_battery()

return { anchor = anchor }
