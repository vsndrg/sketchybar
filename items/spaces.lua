-- Aerospace workspaces: number + real app icons, only occupied/focused ones.
--
-- One fixed-width item (edge → notch) showing one image (see lib/render.lua):
-- a workspace switch is a single content swap. Images for switching to every
-- other visible workspace are pre-rendered, so switches hit the cache.
local config = require("config")
local theme = require("lib.theme")
local render = require("lib.render")
local color = require("lib.color")

local COUNT = 10
local WIDTH = config.side_width.left

sbar.add("event", "aerospace_workspace_change")
sbar.add("event", "aerospace_focus_change")

local palette = theme.palette()

local item = sbar.add("item", "spaces", {
  position = "left",
  width = WIDTH,
  icon = { drawing = false },
  label = { drawing = false },
  background = { drawing = true, color = 0, image = { drawing = true, scale = config.image_scale } },
})

local state = { focused = 0, apps = {} }
local ranges = {}
local seq = 0

local function job_for(focused)
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
  j.fg = color.hex(palette.text)
  j.dim = color.hex(palette.dim)
  j.font = config.font.text
  j.style = config.font.bold
  j.size = config.font.size
  j.max_slots = 8
  j.workspaces = {}
  for i = 1, COUNT do
    local apps = state.apps[i] or {}
    if #apps > 0 or i == focused then
      table.insert(j.workspaces, { n = i, focused = i == focused, apps = apps })
    end
  end
  return render.row({ canvas_w = WIDTH, align = "left", islands = { j } })
end

local function prerender()
  local jobs = {}
  for i = 1, COUNT do
    if i ~= state.focused and #(state.apps[i] or {}) > 0 then jobs[#jobs + 1] = job_for(i) end
  end
  if #jobs > 0 then render.run(jobs) end
end

local function show()
  seq = seq + 1
  local my = seq
  render.run({ job_for(state.focused) }, function(m)
    if my ~= seq then return end
    ranges = m[1].islands[1].ranges or {}
    item:set({ background = { image = { string = m[1].out } } })
    prerender()
  end)
end

-- Data -------------------------------------------------------------------------

local cmd = "aerospace list-workspaces --focused; "
  .. "aerospace list-windows --all --format '%{workspace}|%{app-bundle-id}'"

local fetching, again = false, false
local function refresh()
  if fetching then again = true return end
  fetching = true
  sbar.exec(cmd, function(out)
    fetching = false
    if type(out) == "string" then
      local by_ws, seen, first = {}, {}, true
      for line in out:gmatch("[^\n]+") do
        if first then
          state.focused = tonumber(line) or state.focused
          first = false
        else
          local ws, bundle = line:match("^(%d+)|(.+)$")
          ws = tonumber(ws)
          if ws and bundle and bundle ~= "" then
            by_ws[ws] = by_ws[ws] or {}
            seen[ws] = seen[ws] or {}
            if not seen[ws][bundle] then
              seen[ws][bundle] = true
              table.insert(by_ws[ws], bundle)
            end
          end
        end
      end
      state.apps = by_ws
      show()
    end
    if again then
      again = false
      refresh()
    end
  end)
end

-- Events -----------------------------------------------------------------------

item:subscribe("aerospace_workspace_change", function(env)
  -- switch instantly with what we know (pre-rendered), then reconcile
  local f = tonumber(env.AEROSPACE_FOCUSED_WORKSPACE)
  if f and f ~= state.focused then
    state.focused = f
    show()
  end
  refresh()
end)
item:subscribe({ "aerospace_focus_change", "space_windows_change", "front_app_switched", "system_woke" }, refresh)

-- One click event per action; the workspace is found from the cursor position.
item:subscribe("mouse.clicked", function(env)
  if env.BUTTON == "right" then
    sbar.exec("sketchybar --trigger theme_menu")
    return
  end
  sbar.exec("'" .. config.helper .. "' cursor", function(out)
    local x = tonumber(tostring(out):match("%-?%d+"))
    if not x then return end
    x = x - config.bar.margin
    for _, r in ipairs(ranges) do
      if x >= r[2] and x < r[3] then
        if r[1] ~= state.focused then sbar.exec("aerospace workspace " .. math.floor(r[1])) end
        return
      end
    end
  end)
end)

theme.on(function(p)
  palette = p
  show()
end)

refresh()
