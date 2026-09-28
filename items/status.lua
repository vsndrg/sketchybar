-- Right side, right to left: clock │ battery │ layout — the same on every
-- display. The daemon draws it (lib/bar.lua), shows the battery tooltip on
-- hover and handles clicks (layout: next input source, clock: Calendar).
local bar = require("lib.bar")

sbar.add("event", "layout_change")

-- global events: an invisible item that never goes away. The clock follows
-- `minute_change` from the helper daemon (fired right on the minute); the
-- routine polls the battery and is the clock's fallback.
sbar.add("event", "minute_change")
local events = sbar.add("item", "status", { drawing = false, updates = true, update_freq = 60 })

local state = {
  code = "EN",
  -- assume a battery until pmset says otherwise (no shift at startup on laptops)
  has_battery = true,
  level = 100, charge = 0, low = false, status = "",
}

-- Wording and title case as in the macOS battery menu.
local function status_text(level, charge, remaining)
  if charge == 1 then
    return remaining and (remaining .. " Until Full") or "Charging"
  elseif charge == 2 then
    return level >= 100 and "Fully Charged" or "Not Charging"
  end
  return remaining and (remaining .. " Remaining") or "Calculating Time Remaining…"
end

local function show()
  local t = os.time()
  bar.set("status", {
    input = state.code,
    date = os.date("%a ", t) .. tonumber(os.date("%d", t)) .. os.date(" %b", t),
    time = os.date("%H:%M", t),
    battery = state.has_battery and {
      level = state.level, charge = state.charge, low = state.low, status = state.status,
    } or nil,
  })
end

local function update_battery()
  sbar.exec("pmset -g batt", function(out)
    if type(out) ~= "string" then return end
    -- desktop Macs have no internal battery: drop the island entirely
    state.has_battery = out:find("InternalBattery") ~= nil
    if state.has_battery then
      local ac = out:find("AC Power") ~= nil
      local level = tonumber(out:match("(%d+)%%")) or state.level
      local charging = out:find(";%s*charging") ~= nil or out:find("finishing charge") ~= nil
      local t = out:match("(%d+:%d+) remaining")
      state.level = level
      state.charge = charging and 1 or (ac and 2 or 0)
      state.low = level <= 20 and not ac
      state.status = status_text(level, state.charge, (t and t ~= "0:00") and t or nil)
    end
    show()
  end)
end

-- Events -----------------------------------------------------------------------

events:subscribe("minute_change", show)
events:subscribe("routine", update_battery)
events:subscribe({ "forced", "system_woke", "power_source_change" }, update_battery)

events:subscribe("layout_change", function(env)
  if env.LAYOUT and env.LAYOUT ~= "" and env.LAYOUT ~= state.code then
    state.code = env.LAYOUT
    show()
  end
end)

show()
update_battery()
