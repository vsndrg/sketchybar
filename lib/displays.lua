-- Connected displays, shared by the per-display items (spaces, status).
--
-- aerospace names monitors by NSScreen index (monitor-appkit-nsscreen-screens-id),
-- sketchybar by arrangement id; both map to a CGDirectDisplayID. Displays
-- come and go (Sidecar): items are added/removed live, never by a reload.
-- Each display gets its own bar strip: the bar, or less when its menu bar is
-- lower (see config.strip).
local config = require("config")
local sh = require("lib.sh")

local M = {}

-- { did, arr = arrangement id, mon = NSScreen index, w, notch = width left of
--   the notch (0 = none), menu_bar = menu bar height (0 = unknown),
--   kind = builtin | ipad | display, geo }
M.list = {}
local subs = {}

local screens_cmd = "'" .. config.helper .. "' screens 2>/dev/null"

-- Takes the displays from `barhelper screens` output; false when they can't
-- be read right now.
local function parse(out)
  local screens = {}
  for line in (out or ""):gmatch("[^\n]+") do
    local idx, did, w, notch, mb, kind = line:match("^(%d+) (%d+) (%d+) (%d+) ?(%d*) ?(%a*)$")
    if idx then
      screens[tonumber(did)] = { mon = tonumber(idx), w = tonumber(w), notch = tonumber(notch),
                                 menu_bar = tonumber(mb) or 0, kind = kind ~= "" and kind or "display" }
    end
  end
  local list = {}
  local q = sbar.query("displays")
  for _, x in ipairs(type(q) == "table" and q or {}) do
    local did = tonumber(x.DirectDisplayID)
    local sc = screens[did]
    if sc then
      list[#list + 1] = { did = did, arr = x["arrangement-id"], mon = sc.mon, w = sc.w, notch = sc.notch,
                          menu_bar = sc.menu_bar, kind = sc.kind, geo = config.strip(config.strip_height(sc.menu_bar)) }
    end
  end
  if #list == 0 then return false end -- mid-reconfiguration: keep what we have
  table.sort(list, function(a, b) return a.arr < b.arr end)
  M.list = list
  return true
end

-- Re-reads the displays, then cb(ok) (ok: M.list was updated). Async: event
-- handlers must never block on a process (see lib/sh.lua).
function M.sync(cb)
  sbar.exec(screens_cmd, function(out)
    cb(parse(type(out) == "string" and out or ""))
  end)
end

-- fn() runs after every change of the display set (M.list is up to date).
function M.on_change(fn)
  subs[#subs + 1] = fn
end

local function notify()
  for _, fn in ipairs(subs) do fn() end
end

-- A newly connected display gets its menu bar window a bit later: re-read
-- a few times until every menu bar height is known.
local retries = 0
local function settle_menu_bars()
  for _, d in ipairs(M.list) do
    if d.menu_bar == 0 and retries < 5 then
      retries = retries + 1
      sbar.delay(1, function()
        M.sync(function(ok)
          if ok then notify() end
          settle_menu_bars()
        end)
      end)
      return
    end
  end
end

-- display_change also fires spuriously and in bursts, so settle first.
local events = sbar.add("item", "displays.events", { drawing = false, updates = true })
local settling = false
events:subscribe("display_change", function()
  if settling then return end
  settling = true
  sbar.delay(0.5, function()
    settling = false
    M.sync(function(ok)
      if ok then
        retries = 0
        notify()
        settle_menu_bars()
      end
    end)
  end)
end)

-- at startup the items are built from the list right away
parse(sh.run(screens_cmd))
settle_menu_bars()

return M
