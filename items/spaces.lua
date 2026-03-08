local colors    = require("colors")
local icons     = require("icons")
local settings  = require("settings")
local app_icons = require("helpers.app_icons")

sbar.add("event", "aerospace_workspace_change")
sbar.add("event", "refresh_spaces_visibility")

-- Single aerospace call to get all windows across all workspaces (~34ms vs ~1.3s for 10 calls)
local function get_all_workspace_apps_async(callback)
  sbar.exec("aerospace list-windows --all --format '%{workspace}|%{app-name}' 2>/dev/null", function(output)
    local ws_apps = {}
    for i = 1, 10 do ws_apps[i] = {} end
    for line in output:gmatch("[^\r\n]+") do
      local ws, app = line:match("^(%d+)|(.+)$")
      ws = tonumber(ws)
      if ws and app and app ~= "" then
        app = app:match("^%s*(.-)%s*$")  -- trim
        if ws_apps[ws] then
          ws_apps[ws][app] = (ws_apps[ws][app] or 0) + 1
        end
      end
    end
    callback(ws_apps)
  end)
end

local function build_icon_line(apps)
  local line = ""
  local empty = true
  for app, _ in pairs(apps) do
    empty = false
    local lookup = app_icons[app]
    line = line .. ((lookup == nil) and app_icons["Default"] or lookup)
  end
  return empty and "" or line
end

local spaces         = {}
local space_paddings = {}
local focused_ws     = 1
local spaces_visible = true

-- Create all 10 space items immediately (drawing=false, will be updated async)
for i = 1, 10, 1 do
  local space = sbar.add("item", "space." .. i, {
    updates       = true,
    drawing       = false,
    padding_left  = 2,
    padding_right = 2,
    icon = {
      string        = tostring(i),
      font          = {
        family = settings.font.numbers,
        style  = settings.font.style_map["Bold"],
        size   = 11.0,
      },
      color         = colors.grey,
      padding_left  = 8,
      padding_right = 8,
    },
    label = {
      string        = "",
      font          = "sketchybar-app-font:Regular:13.0",
      color         = colors.grey,
      padding_left  = 0,
      padding_right = 8,
    },
    background = {
      height        = 22,
      corner_radius = 6,
      color         = colors.bg1,
      border_width  = 0,
    },
    popup = { background = { border_width = 1, border_color = colors.popup.border } }
  })

  spaces[i] = space

  local space_popup = sbar.add("item", {
    position      = "popup." .. space.name,
    padding_left  = 5,
    padding_right = 0,
    background    = {
      drawing = true,
      image   = { corner_radius = 9, scale = 0.2 }
    }
  })

  local pad = sbar.add("item", "space.padding." .. i, {
    drawing       = false,
    width         = 4,
    padding_left  = 0,
    padding_right = 0,
    background    = { drawing = false },
    label         = { drawing = false },
    icon          = { drawing = false },
  })
  space_paddings[i] = pad

  space:subscribe("aerospace_workspace_change", function(env)
    if not spaces_visible then return end

    local fw       = tonumber(env.AEROSPACE_FOCUSED_WORKSPACE)
    local sel_now  = (fw == i)

    space:set({
      icon       = { color = sel_now and colors.black or colors.grey },
      label      = { color = sel_now and colors.black or colors.grey },
      background = { color = sel_now and colors.accent or colors.bg1 },
    })
  end)

  space:subscribe("mouse.clicked", function(env)
    if env.BUTTON == "other" then
      space_popup:set({ background = { image = "space." .. i } })
      space:set({ popup = { drawing = "toggle" } })
    else
      sbar.exec("aerospace workspace " .. i)
    end
  end)

  space:subscribe("mouse.entered", function(_)
    if not spaces_visible then return end

    local is_focused = (i == focused_ws)

    space:set({
      icon = {
        color = is_focused and colors.black or colors.white,
      },
      label = {
        color = is_focused and colors.black or colors.white,
      },
      background = {
        color        = is_focused and colors.accent or colors.with_alpha(colors.grey, 0.25),
        border_width = is_focused and 0 or 1,
        border_color = is_focused and colors.transparent or colors.accent,
      },
    })
  end)

  space:subscribe("mouse.exited", function(_)
    local is_focused = (i == focused_ws)

    if space:query().popup.drawing == "on" then
      space:set({ popup = { drawing = false } })
    end

    space:set({
      icon = {
        color = is_focused and colors.black or colors.grey,
      },
      label = {
        color = is_focused and colors.black or colors.grey,
      },
      background = {
        color        = is_focused and colors.accent or colors.bg1,
        border_width = 0,
        border_color = colors.transparent,
      },
    })
  end)
  -- space:subscribe("mouse.exited", function(_)
  --   if space:query().popup.drawing == "on" then
  --     space:set({ popup = { drawing = false } })
  --   end
  -- end)
end

-- Full refresh (async) — one aerospace call for all workspaces
local function refresh_all_spaces_async()
  sbar.exec("aerospace list-workspaces --focused 2>/dev/null", function(result)
    focused_ws = tonumber(result:match("%d+")) or focused_ws

    get_all_workspace_apps_async(function(ws_apps)
      for i = 1, 10 do
        local apps = ws_apps[i]
        local sel = (i == focused_ws)
        local has_win = false
        for _ in pairs(apps) do has_win = true; break end
        local should_draw = sel or has_win

        spaces[i]:set({
          drawing    = should_draw,
          icon       = { color = sel and colors.black or colors.grey },
          label      = {
            color  = sel and colors.black or colors.grey,
            string = build_icon_line(apps),
          },
          background = { color = sel and colors.accent or colors.bg1 },
        })
        space_paddings[i]:set({ drawing = should_draw })
      end
    end)
  end)
end

-- Kick off async init
refresh_all_spaces_async()

-- Observer: tracks focused workspace and updates app icon lines (async)
local observer = sbar.add("item", { drawing = false, updates = true })

observer:subscribe("aerospace_workspace_change", function(env)
  local pw = tonumber(env.AEROSPACE_PREV_WORKSPACE)
  local fw = tonumber(env.AEROSPACE_FOCUSED_WORKSPACE)

  focused_ws = fw or focused_ws

  -- Single call to get all workspace data, then update prev + focused + visibility
  get_all_workspace_apps_async(function(ws_apps)
    for i = 1, 10 do
      local apps = ws_apps[i]
      local sel = (i == focused_ws)
      local has_win = false
      for _ in pairs(apps) do has_win = true; break end
      local should_draw = sel or has_win
      local line = build_icon_line(apps)

      spaces[i]:set({
        drawing = should_draw,
        label   = { string = line },
      })
      space_paddings[i]:set({ drawing = should_draw })
    end
  end)
end)

-- Handle refresh request (from menus.lua when switching back to spaces view)
observer:subscribe("refresh_spaces_visibility", function()
  spaces_visible = true
  refresh_all_spaces_async()
end)

-- Spaces / Menus toggle indicator
local spaces_indicator = sbar.add("item", {
  padding_left  = 0,
  padding_right = 0,
  icon = {
    padding_left  = 6,
    padding_right = 6,
    color         = colors.grey,
    string        = icons.switch.on,
    font          = {
      family = settings.font.text,
      style  = settings.font.style_map["Regular"],
      size   = 12.0,
    },
  },
  label = {
    width         = 0,
    padding_left  = 0,
    padding_right = 6,
    string        = "Spaces",
    color         = colors.grey,
  },
  background = {
    color        = colors.transparent,
    border_color = colors.transparent,
  }
})

spaces_indicator:subscribe("swap_menus_and_spaces", function(env)
  local on = spaces_indicator:query().icon.value == icons.switch.on
  spaces_indicator:set({ icon = on and icons.switch.off or icons.switch.on })
  if on then
    spaces_visible = false
  end
end)

spaces_indicator:subscribe("mouse.entered", function(_)
  spaces_indicator:set({ icon = { color = colors.accent } })
end)

spaces_indicator:subscribe("mouse.exited", function(_)
  spaces_indicator:set({ icon = { color = colors.grey } })
end)

spaces_indicator:subscribe("mouse.clicked", function(_)
  sbar.trigger("swap_menus_and_spaces")
end)
