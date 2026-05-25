-- lua/paneity/guess_command.lua
--
-- Shipped default handlers for the new-command popup's guess pipeline.
-- Each entry takes a ctx table (see paneity.init `_build_ctx`) and returns
-- either a string (the prefill) or nil to fall through to `default`.
-- `default` is the catch-all and is always called when a filetype handler
-- doesn't match.

local M = {}

function M.default(ctx)
  if ctx.has_file("Makefile") then return "make" end
  return ctx.relpath
end

return M
