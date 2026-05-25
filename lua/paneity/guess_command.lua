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

function M.ruby(ctx)
  if ctx.relpath:match("_spec%.rb$") or ctx.relpath:match("^spec/") or ctx.relpath:match("/spec/") then
    return "bundle exec rspec " .. ctx.relpath
  end
  if ctx.relpath:match("_test%.rb$") or ctx.relpath:match("^test/") or ctx.relpath:match("/test/") then
    return "bundle exec rake test TEST=" .. ctx.relpath
  end
  return "ruby " .. ctx.relpath
end

function M.rust(ctx)
  if ctx.find_ancestor("Cargo.toml") then return "cargo test" end
end

function M.lua(ctx)
  if ctx.relpath:match("_spec%.lua$") and ctx.has_file("Makefile") then
    return "make test"
  end
end

return M
