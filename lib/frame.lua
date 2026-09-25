-- Atomic updates for multi-item UI (the theme menu): render any missing
-- assets first, then send every property change as ONE sketchybar message.
local shape = require("lib.shape")

local M = {}
local seq = {}
local held = nil -- commits queued while the initial config transaction is open

function M.hold() held = {} end

function M.release()
  local queue = held
  held = nil
  for _, c in ipairs(queue or {}) do M.commit(table.unpack(c)) end
end

-- key: owner id (a newer commit for the same key supersedes an older one)
function M.commit(key, assets, fn)
  if held then
    table.insert(held, { key, assets, fn })
    return
  end
  seq[key] = (seq[key] or 0) + 1
  local my = seq[key]
  shape.ensure(assets or {}, function()
    if seq[key] ~= my then return end
    sbar.begin_config()
    fn()
    sbar.end_config()
  end)
end

return M
