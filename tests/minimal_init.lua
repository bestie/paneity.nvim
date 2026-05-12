-- Minimal init for running plenary-based tests in headless Neovim.
-- Prepend plenary and the repo root to runtimepath, then load plenary's
-- plugin so `PlenaryBustedDirectory` is registered.

local repo_root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h")
local plenary_path = repo_root .. "/deps/plenary.nvim"

vim.opt.runtimepath:prepend(plenary_path)
vim.opt.runtimepath:prepend(repo_root)

vim.cmd("runtime plugin/plenary.vim")
