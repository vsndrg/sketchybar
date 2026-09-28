-- The bar's state for the helper daemon, which draws the bar itself (Liquid
-- Glass windows, helper/bar.swift) and handles its clicks and hover. Every
-- part sets its own section; the whole state goes to
-- ~/.local/state/sketchybar/bar.json, atomically and only when it changed —
-- the daemon watches the directory, so an update spawns nothing.
local config = require("config")
local json = require("lib.json")

local M = {}
local sections = {}
local path = config.state .. "/bar.json"
local written

function M.set(key, value)
  sections[key] = value
  local body = json.encode(sections)
  if body == written then return end
  local f = io.open(path .. ".tmp", "w")
  if not f then return end
  f:write(body, "\n")
  f:close()
  os.rename(path .. ".tmp", path)
  written = body
end

return M
