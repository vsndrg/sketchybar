-- Aerospace workspaces: number + real app icons, every existing workspace
-- (occupied, or shown on some display) on every display's bar.
--
-- Workspaces live on monitors (the aerospace default). On each display's bar
-- the workspace it shows gets the lens (clear glass on the focused display, a
-- subdued one on the others); workspaces living on another display carry that
-- display's device glyph (laptop, iPad, monitor) after the digit — so any
-- workspace can be found from any bar, and it's clear where a click leads.
--
-- The daemon draws it (lib/bar.lua) and handles clicks and hover itself; this
-- keeps the state.
local bar = require("lib.bar")
local screens = require("lib.displays")

sbar.add("event", "aerospace_workspace_change")
sbar.add("event", "aerospace_focus_change")

local MAIN = 1 -- NSScreen index of the main monitor: new workspaces open there

-- global events are handled once, by an invisible item that never goes away
local events = sbar.add("item", "spaces.events", { drawing = false, updates = true })

-- State -------------------------------------------------------------------------

-- ws[n] = monitor (NSScreen index) workspace n lives on; shown[mon] = workspace
-- that monitor shows; focused = focused workspace, on monitor focused_mon.
local state = { ws = {}, shown = {}, focused = 0, focused_mon = MAIN, apps = {} }

local function monitor_of(st, n)
  return st.ws[n] or MAIN
end

-- SF Symbol of each display kind (see lib/displays.lua)
local device_symbol = { builtin = "laptopcomputer", ipad = "ipad.landscape", display = "display" }

local function device_of(mon)
  for _, d in ipairs(screens.list) do
    if d.mon == mon then return device_symbol[d.kind] or device_symbol.display end
  end
  return device_symbol.display
end

-- The state right after `aerospace workspace n` (cmd-N / a click): n shows on
-- the monitor it lives on, which takes focus.
local function switched(st, n)
  local mon = monitor_of(st, n)
  local shown = {}
  for m, w in pairs(st.shown) do shown[m] = w end
  shown[mon] = n
  local ws = {}
  for w, m in pairs(st.ws) do ws[w] = m end
  ws[n] = mon
  return { ws = ws, shown = shown, focused = n, focused_mon = mon, apps = st.apps }
end

-- Existing workspaces: occupied or shown somewhere, in numeric order.
local function existing(st)
  local set, list = {}, {}
  for n, apps in pairs(st.apps) do if #apps > 0 then set[n] = true end end
  for _, n in pairs(st.shown) do set[n] = true end
  for n in pairs(set) do list[#list + 1] = n end
  table.sort(list)
  return list
end

local function show()
  local out = {}
  for _, d in ipairs(screens.list) do
    local spaces = {}
    for _, n in ipairs(existing(state)) do
      local mon = monitor_of(state, n)
      local here = mon == d.mon
      spaces[#spaces + 1] = {
        n = n,
        apps = state.apps[n] or {},
        shown = (here and state.shown[d.mon] == n) or nil,
        device = (not here) and device_of(mon) or nil,
      }
    end
    out[#out + 1] = { did = d.did, strip = d.geo.strip, focused = state.focused_mon == d.mon, spaces = spaces }
  end
  bar.set("displays", out)
end

-- Data -------------------------------------------------------------------------

local cmd = "aerospace list-workspaces --all --format "
  .. "'%{workspace}|%{monitor-appkit-nsscreen-screens-id}|%{workspace-is-visible}|%{workspace-is-focused}'; "
  .. "aerospace list-windows --all --format '%{workspace}|%{app-bundle-id}'"

-- A refresh started before the latest workspace event may answer with the
-- previous arrangement; its window list is still fine, the rest is not.
local switch_seq = 0

local fetching, again = false, false
local function refresh()
  if fetching then again = true return end
  fetching = true
  local started = switch_seq
  sbar.exec(cmd, function(out)
    fetching = false
    if type(out) == "string" then
      local by_ws, seen = {}, {}
      local ws, shown, focused, focused_mon = {}, {}, nil, nil
      for line in out:gmatch("[^\n]+") do
        local n, mon, vis, foc = line:match("^(%d+)|(%d+)|(%a+)|(%a+)$")
        if n then
          n, mon = tonumber(n), tonumber(mon)
          ws[n] = mon
          if vis == "true" then shown[mon] = n end
          if foc == "true" then focused, focused_mon = n, mon end
        else
          local w, bundle = line:match("^(%d+)|(.+)$")
          w = tonumber(w)
          if w and bundle and bundle ~= "" then
            by_ws[w] = by_ws[w] or {}
            seen[w] = seen[w] or {}
            if not seen[w][bundle] then
              seen[w][bundle] = true
              table.insert(by_ws[w], bundle)
            end
          end
        end
      end
      state.apps = by_ws
      if started == switch_seq and focused then
        state.ws, state.shown = ws, shown
        state.focused, state.focused_mon = focused, focused_mon
      end
      show()
    end
    if again then
      again = false
      refresh()
    end
  end)
end

-- Events -----------------------------------------------------------------------

events:subscribe("aerospace_workspace_change", function(env)
  local f = tonumber(env.AEROSPACE_FOCUSED_WORKSPACE)
  switch_seq = switch_seq + 1
  -- Switch instantly with what we know, then reconcile. The prediction is
  -- `workspace f` (f shows on its own monitor, which takes focus); only a
  -- summon from another monitor differs, and the refresh fixes that.
  if f and f ~= state.focused then
    state = switched(state, f)
    show()
  end
  refresh()
end)
events:subscribe({ "aerospace_focus_change", "space_windows_change", "front_app_switched", "system_woke" }, refresh)

-- Display set changes (Sidecar connect/disconnect); aerospace rearranges too.
screens.on_change(refresh)

refresh()
