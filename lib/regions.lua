-- Hover regions for the helper daemon (it fires `bar_hover REGION=<name>`
-- when the cursor enters/leaves one). Every item owns its own set; the file
-- holds all of them: "<name> <left|right> <d0> <d1> [display]", [d0, d1)
-- measured from that edge of the screen under the cursor, only on that
-- CGDirectDisplayID when given.
local config = require("config")

local M = {}
local owners = {}
local path = config.state .. "/regions"

local function write()
  local lines = { string.format("strip %d", config.bar.height) }
  for _, list in pairs(owners) do
    for _, r in ipairs(list) do
      lines[#lines + 1] = string.format("%s %s %g %g", r[1], r[2], r[3], r[4])
        .. (r[5] and (" " .. r[5]) or "")
    end
  end
  local f = io.open(path .. ".tmp", "w")
  if not f then return end
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
  os.rename(path .. ".tmp", path)
end

-- list: { { name, "left" | "right", d0, d1 [, display id] }, ... }
function M.set(owner, list)
  owners[owner] = list
  write()
end

return M
