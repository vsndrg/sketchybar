-- Right side, right to left: clock │ battery │ layout — three islands drawn
-- into ONE fixed-width item (notch → edge), so any change (a minute ticking,
-- the date, a charging bolt) is a single content swap with nothing shifting.
local config = require("config")
local theme = require("lib.theme")
local render = require("lib.render")
local color = require("lib.color")

local font = config.font
local WIDTH = config.side_width.right
local ORIGIN = config.screen.width - config.bar.margin - WIDTH -- global x of the item
local palette = theme.palette()

sbar.add("event", "layout_change")
sbar.add("event", "bar_hover")

-- Zero-width anchor at the right edge; the theme menu hangs off it.
local anchor = sbar.add("item", "menu.anchor", {
  position = "right",
  width = 0,
  popup = { align = "right", horizontal = true, height = config.popup.height, y_offset = 4 },
})

local item = sbar.add("item", "status", {
  position = "right",
  width = WIDTH,
  updates = true,
  update_freq = 10,
  icon = { drawing = false },
  label = { drawing = false },
  background = { drawing = true, color = 0, image = { drawing = true, scale = config.image_scale } },
  popup = { align = "right", horizontal = true, height = config.island.height, y_offset = 4 },
})

-- Battery tooltip: its canvas reaches from the bubble to the right edge, so a
-- right-aligned popup puts the bubble centered under the battery.
local tip = sbar.add("item", "status.tip", {
  position = "popup." .. item.name,
  icon = { drawing = false },
  label = { drawing = false },
  background = { drawing = true, color = 0, image = { drawing = true, scale = config.image_scale } },
})

local state = {
  code = "EN",
  level = 100, charge = 0, low = false, status = "",
}
local islands = {} -- x ranges from the last render: input, battery, clock
local seq = 0

local function status_text(level, charge, remaining)
  if charge == 1 then
    return remaining and ("Charging · full in " .. remaining) or "Charging"
  elseif charge == 2 then
    return level >= 100 and "Fully charged" or "On power · not charging"
  end
  return remaining and (remaining .. " remaining") or "Estimating time left…"
end

local function text(str, style, c, extra)
  local t = { type = "text", text = str, font = font.text, style = style, size = font.size, color = color.hex(c) }
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end

local function write_regions()
  local b = islands[2]
  if not b then return end
  local f = io.open(config.state .. "/regions", "w")
  if not f then return end
  f:write(string.format("strip %d\nbattery %g %g\n", config.bar.height, ORIGIN + b.x0, ORIGIN + b.x1))
  f:close()
end

local function show()
  seq = seq + 1
  local my = seq

  local input = render.base("island", palette)
  input.pad_l, input.pad_r = 10, 10
  input.parts = { text(state.code, font.bold, palette.muted, { min_text = "RU", align = "center" }) }

  local battery = render.base("island", palette)
  battery.pad_l, battery.pad_r = 10, 10
  battery.parts = { { type = "battery", level = state.level, state = state.charge,
    color = color.hex(state.low and palette.red or palette.text) } }

  local d = os.date("%a ") .. tonumber(os.date("%d")) .. os.date(" %b")
  local clock = render.base("island", palette)
  clock.pad_l, clock.pad_r = 10, 10
  clock.parts = {
    text(d, font.medium, palette.muted),
    { type = "gap", w = 6 },
    -- widest digits reserve the width, so the island never changes minute to minute
    text(os.date("%H:%M"), font.bold, palette.text, { min_text = "00:00", align = "right" }),
  }

  local row = render.row({ canvas_w = WIDTH, align = "right", gap = config.island.gap,
    islands = { input, battery, clock } })

  render.run({ row }, function(m)
    if my ~= seq then return end
    islands = m[1].islands
    item:set({ background = { image = { string = m[1].out } } })
    write_regions()

    -- tooltip for the current battery state (rendered ahead of any hover)
    local b = islands[2]
    local bubble = render.base("island", palette)
    bubble.fill = color.hex(palette.popup)
    bubble.pad_l, bubble.pad_r = 10, 10
    bubble.parts = { text(state.status, font.medium, palette.muted) }
    local t = render.row({ center_from_right = WIDTH - (b.x0 + b.x1) / 2, align = "left", islands = { bubble } })
    render.run({ t }, function(tm)
      if my ~= seq then return end
      tip:set({ width = math.ceil(tm[1].width), background = { image = { string = tm[1].out } } })
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

local ticks = 0
item:subscribe("routine", function()
  ticks = ticks + 1
  if ticks % 6 == 0 then update_battery() else tick() end
end)
item:subscribe({ "forced", "system_woke", "power_source_change" }, update_battery)

item:subscribe("layout_change", function(env)
  if env.LAYOUT and env.LAYOUT ~= "" and env.LAYOUT ~= state.code then
    state.code = env.LAYOUT
    show()
  end
end)

item:subscribe("bar_hover", function(env)
  item:set({ popup = { drawing = env.REGION == "battery" } })
end)

item:subscribe("mouse.clicked", function(env)
  if env.BUTTON == "right" then
    sbar.exec("sketchybar --trigger theme_menu")
    return
  end
  sbar.exec("'" .. config.helper .. "' cursor", function(out)
    local x = tonumber(tostring(out):match("%-?%d+"))
    if not x then return end
    x = x - ORIGIN
    local function inside(i) return islands[i] and x >= islands[i].x0 and x < islands[i].x1 end
    if inside(1) then
      sbar.exec("'" .. config.helper .. "' layout next")
    elseif inside(3) then
      sbar.exec("open -a Calendar")
    end
  end)
end)

theme.on(function(p)
  palette = p
  show()
end)

update_battery()

return { anchor = anchor }
