-- Synchronous shell commands, for startup only (event handlers use sbar.exec).
--
-- SbarLua ignores SIGCHLD (its sbar.exec children are reaped by the kernel)
-- except around its os.execute, which restores the default for system(): a
-- sbar.exec child exiting in that window stays a zombie for good, and with a
-- zombie around, a later pclose() can block forever in wait4 — the bar froze
-- in io.popen that way. So: no os.execute once sketchybar is loaded.
local M = {}

-- Runs cmd, returns its stdout.
function M.run(cmd)
  local f = io.popen(cmd)
  local out = f and f:read("*a") or ""
  if f then f:close() end
  return out
end

return M
