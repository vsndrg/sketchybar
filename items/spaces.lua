-- Aerospace workspaces: number + real app icons, every existing workspace
-- (occupied, or shown on some display) on every display's bar.
--
-- Workspaces live on monitors (the aerospace default). Each display has its
-- own item: the workspace it shows gets the pill (vivid on the focused
-- display, idle on the others), workspaces living on another display carry
-- that display's device glyph (laptop, iPad, monitor) after the digit — so any
-- workspace can be found from any bar, and it's clear where a click leads —
-- and the focused one, when it is on another display, gets a dashed outline.
--
-- One fixed-width item (edge → notch, or → the status on displays without a
-- notch) per display showing one image (see lib/render.lua): a workspace
-- switch is a single content swap. Images for switching to every other
-- visible workspace are pre-rendered, so switches hit the cache. The layout
-- is left-aligned; device glyphs differ per display, so do click/hover ranges.
local config = require("config")
local theme = require("lib.theme")
local render = require("lib.render")
local color = require("lib.color")
local regions = require("lib.regions")
local screens = require("lib.displays")

sbar.add("event", "aerospace_workspace_change")
sbar.add("event", "aerospace_focus_change")

local palette = theme.palette()

-- Displays ----------------------------------------------------------------------

local MAIN = 1 -- NSScreen index of the main monitor: new workspaces open there
local displays = {} -- { did, arr, mon, kind, width, geo, item, hovered, ranges }
local by_did = {}
local clicked -- mouse.clicked handler, defined below

-- global events are handled once, by an invisible item that never goes away
local events = sbar.add("item", "spaces.events", { drawing = false, updates = true })

local function sync_displays()
  local seen, now = {}, {}
  for _, x in ipairs(screens.list) do
    local width = config.left_width(x.w, x.notch)
    local d = by_did[x.did]
    if not d then
      d = { did = x.did, hovered = 0 }
      d.item = sbar.add("item", "spaces." .. x.did, {
        position = "left",
        display = x.arr,
        width = width,
        y_offset = x.geo.y_offset,
        icon = { drawing = false },
        label = { drawing = false },
        background = { drawing = true, color = 0, image = { drawing = true, scale = config.image_scale } },
      })
      d.item:subscribe("mouse.clicked", clicked)
      by_did[x.did] = d
    elseif d.arr ~= x.arr or d.width ~= width or d.geo.strip ~= x.geo.strip then
      d.item:set({ display = x.arr, width = width, y_offset = x.geo.y_offset })
    end
    d.arr, d.mon, d.kind, d.width, d.geo = x.arr, x.mon, x.kind, width, x.geo
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

-- State -------------------------------------------------------------------------

-- ws[n] = monitor (NSScreen index) workspace n lives on; shown[mon] = workspace
-- that monitor shows; focused = focused workspace, on monitor focused_mon.
local state = { ws = {}, shown = {}, focused = 0, focused_mon = MAIN, apps = {} }
local seq = 0
local icon_theme = "" -- system icon theme, see icon_theme_change

local function monitor_of(st, n)
  return st.ws[n] or MAIN
end

-- SF Symbol of each display kind (see lib/displays.lua)
local device_symbol = { builtin = "laptopcomputer", ipad = "ipad.landscape", display = "display" }

local function device_of(mon)
  for _, d in ipairs(displays) do
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

local function job_for(d, st, hovered)
  local j = render.base("spaces", palette)
  j.inset = config.pill.inset
  j.pad = 7              -- pill edge → digit
  j.num_gap = 3          -- digit → first icon
  j.icon = config.app_icon_size
  j.slot = config.app_icon_size + 2
  j.tail = 5             -- icons carry ~1.5pt of built-in margin, so 5 reads as 7
  j.pill_h = config.pill.height
  j.pill_r = config.pill.radius
  j.pill = color.hex(palette.pill)
  j.pill_idle = color.hex(palette.pill_idle)
  j.ring = color.hex(palette.pill)
  j.ring_w = 1           -- dashed outline of the focused workspace seen from another display
  j.hover = color.hex(palette.hover)
  j.hover_fg = color.hex(palette.muted)
  j.fg = color.hex(palette.text)
  j.dim = color.hex(palette.dim)
  j.device_w = 16        -- device glyph width
  j.device_slot = 18
  j.font = config.font.text
  j.style = config.font.bold
  j.size = config.font.size
  j.max_slots = 8
  j.icon_theme = icon_theme -- part of the cache key only: icons are baked in
  j.workspaces = {}
  for _, n in ipairs(existing(st)) do
    local mon = monitor_of(st, n)
    local here = mon == d.mon
    local shown = here and st.shown[d.mon] == n
    table.insert(j.workspaces, {
      n = n,
      focused = shown or nil,
      idle = (shown and st.focused_mon ~= d.mon) or nil,
      device = (not here) and device_of(mon) or nil,
      -- the focused workspace lives on another display: outline it here
      ring = (not here and n == st.focused) or nil,
      -- hovered is ignored on the shown workspace, so that image is shared
      -- with the plain state and stays cached
      hovered = (n == hovered and not shown) or nil,
      apps = st.apps[n] or {},
    })
  end
  -- drawn at the bar's size, shown scaled to the display's strip
  return render.row({ canvas_w = d.width / d.geo.scale, align = "left", islands = { j } }, d.geo)
end

-- Every state one step away is rendered ahead: switching to any visible
-- workspace (on every display), and hovering any of them, both hit the cache.
local function prerender()
  local jobs = {}
  for _, n in ipairs(existing(state)) do
    if n ~= state.focused then
      local st = switched(state, n)
      for _, d in ipairs(displays) do
        jobs[#jobs + 1] = job_for(d, st, d.hovered)
        if n ~= d.hovered then jobs[#jobs + 1] = job_for(d, state, n) end
      end
    end
  end
  if #jobs > 0 then render.run(jobs) end
end

local function show()
  seq = seq + 1
  local my = seq
  local jobs = {}
  for i, d in ipairs(displays) do jobs[i] = job_for(d, state, d.hovered) end
  render.run(jobs, function(m)
    if my ~= seq then return end
    sbar.begin_config()
    for i, d in ipairs(displays) do
      d.item:set({ background = { image = { string = m[i].out } } })
    end
    sbar.end_config()
    -- ranges are in the bar's units; scaled per display
    local list = {}
    for i, d in ipairs(displays) do
      local s = d.geo.scale
      d.ranges = m[i].islands[1].ranges or {}
      for _, r in ipairs(d.ranges) do
        list[#list + 1] = { "space." .. math.floor(r[1]), "left",
                            config.bar.margin + r[2] * s, config.bar.margin + r[3] * s, d.did }
      end
    end
    regions.set("spaces", list)
    prerender()
  end)
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
  -- Switch instantly with what we know (pre-rendered), then reconcile. The
  -- prediction is `workspace f` (f shows on its own monitor, which takes focus);
  -- only a summon from another monitor differs, and the refresh fixes that.
  if f and f ~= state.focused then
    state = switched(state, f)
    show()
  end
  refresh()
end)
events:subscribe({ "aerospace_focus_change", "space_windows_change", "front_app_switched", "system_woke" }, refresh)

-- System icon theme changed (helper daemon): every cached image is stale.
sbar.add("event", "icon_theme_change")
events:subscribe("icon_theme_change", function(env)
  icon_theme = env.THEME or ""
  show()
end)

sbar.add("event", "bar_hover")
events:subscribe("bar_hover", function(env)
  local n = tonumber((env.REGION or ""):match("^space%.(%d+)$")) or 0
  local did = tonumber(env.DISPLAY)
  local changed = false
  for _, d in ipairs(displays) do
    -- without a display id (old daemon) every display shows the hover
    local h = (did == nil or d.did == did or d.did == 0) and n or 0
    if h ~= d.hovered then
      d.hovered = h
      changed = true
    end
  end
  if changed then show() end
end)

-- One click event per action; the workspace is found from the cursor position
-- (ranges are in the bar's units, scaled on displays with a shorter strip).
clicked = function(env)
  if env.BUTTON == "right" then
    sbar.exec("sketchybar --trigger theme_menu")
    return
  end
  -- "<x on the screen under the cursor> <that screen's width> <its display id>"
  sbar.exec("'" .. config.helper .. "' cursor", function(out)
    local x, did = tostring(out):match("^%s*(%-?%d+)%s+%d+%s*(%d*)")
    x = tonumber(x)
    if not x then return end
    local d = by_did[tonumber(did)] or displays[1]
    if not (d and d.ranges) then return end
    x = (x - config.bar.margin) / d.geo.scale
    for _, r in ipairs(d.ranges) do
      if x >= r[2] and x < r[3] then
        if r[1] ~= state.focused then sbar.exec("aerospace workspace " .. math.floor(r[1])) end
        return
      end
    end
  end)
end

-- Display set changes (Sidecar connect/disconnect); aerospace rearranges too.
screens.on_change(function()
  sync_displays()
  refresh()
end)

sync_displays()

theme.on(function(p)
  palette = p
  show()
end)

refresh()
