-- scripts/try-init.lua
--
-- Minimal nvim init for trying out paneity locally. Used by
-- scripts/try. Loads paneity from this repo (no plugin manager
-- needed), sets <Space> as leader, and calls setup with defaults.
--
-- Run with:  nvim --clean -u scripts/try-init.lua [file]
-- Or via:    scripts/try

local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

vim.opt.runtimepath:prepend(repo)
vim.g.mapleader = " "

-- Debug logging on by default in the try environment. Output is
-- appended to /tmp/paneity.log; tail it from another terminal.
require("paneity").setup({ log_level = vim.log.levels.DEBUG })

vim.schedule(function()
  print("paneity loaded from " .. repo)
  print("Try: <Space>tp to pick/create a target pane, then <Space>tc to open the popup")
  print("Logs: tail -f /tmp/paneity.log")
end)
