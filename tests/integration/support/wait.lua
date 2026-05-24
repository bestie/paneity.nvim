-- tests/integration/support/wait.lua
--
-- Tiny polling helper. Returns true when `predicate` becomes true within
-- `timeout_ms`, false on timeout.

local M = {}

function M.until_true(predicate, timeout_ms, interval_ms)
  return vim.wait(timeout_ms, predicate, interval_ms or 50)
end

return M
