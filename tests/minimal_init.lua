-- Minimal init for running plenary-based tests in headless Neovim.
-- Prepend plenary and the repo root to runtimepath, then load plenary's
-- plugin so `PlenaryBustedDirectory` is registered.
--
-- We also extend Lua's package.path with the repo root so test helpers
-- under `tests/...` are requireable as e.g. `tests.integration.support.tmux`.
-- The runtimepath prepend only covers `lua/?.lua`, which is for plugin code.

local repo_root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h")
local plenary_path = repo_root .. "/deps/plenary.nvim"

vim.opt.runtimepath:prepend(plenary_path)
vim.opt.runtimepath:prepend(repo_root)

package.path = table.concat({
  repo_root .. "/?.lua",
  repo_root .. "/?/init.lua",
  package.path,
}, ";")

vim.cmd("runtime plugin/plenary.vim")
