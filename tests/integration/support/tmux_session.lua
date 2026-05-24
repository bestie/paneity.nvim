-- tests/integration/support/tmux_session.lua
--
-- Isolated tmux session lifecycle for integration tests, with optional
-- `start_nvim` to launch a real Neovim into it.
--
-- One sandbox is hidden inside each session: setting TMUX_TMPDIR to a
-- fresh temp dir means this helper's tmux invocations and the plugin's
-- own `io.popen` calls share the same private socket, so tests never
-- touch the developer's real session. The tmpdir itself is not part of
-- the public API — use `session:path(rel)` to get paths inside it.
--
-- Typical use:
--
--   local session = tmux_session.start({ name = "feature_x" })
--   session:start_nvim()              -- blocks until paneity is loaded
--   session:send_keys("Space t p")    -- drive the workflow
--   -- ... assert observable effects ...
--   session:destroy()                 -- in after_each
--
-- Host-runtime touchpoints (`vim.fn.system`, `vim.fn.shellescape`,
-- `vim.env`, `vim.wait`) are encapsulated here so spec bodies stay
-- free of `vim.*` plumbing.

local M = {}

-- Repo root, derived from this helper's own source path:
--   tests/integration/support/tmux_session.lua  ->  four `:h` to the root.
local HELPER_SOURCE = debug.getinfo(1, "S").source:sub(2)
local REPO_ROOT = vim.fn.fnamemodify(vim.fn.resolve(HELPER_SOURCE), ":p:h:h:h:h")

-- Default inner-init: put paneity on the rtp, set leader BEFORE setup
-- so `<leader>...` mappings bind to <Space>. Specs override via
-- start_nvim({ init_lines = ... }) when they need different config.
local DEFAULT_INIT_LINES = {
  string.format("vim.opt.runtimepath:prepend(%q)", REPO_ROOT),
  "vim.g.mapleader = ' '",
  "require('paneity').setup({})",
}

local function trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function sh(cmd)
  return trim(vim.fn.system(cmd))
end

local function tmux_cmd(args)
  return sh("tmux " .. args)
end

-- start(opts):
--   opts.name    tmux session name (default "paneity_integration")
--   opts.width   pane width  (default 200)
--   opts.height  pane height (default 50)
--
-- Creates an isolated tmux server (private TMUX_TMPDIR) and a detached
-- session running the default shell. No nvim yet — call `start_nvim`
-- on the returned session to launch one.
function M.start(opts)
  opts = opts or {}
  local name   = opts.name   or "paneity_integration"
  local width  = opts.width  or 200
  local height = opts.height or 50

  local tmpdir = sh("mktemp -d")
  vim.env.TMUX_TMPDIR = tmpdir

  tmux_cmd(string.format(
    "new-session -d -s %s -x %d -y %d", name, width, height))

  local session = { name = name, tmpdir = tmpdir }

  -- Absolute path inside this session's private tmpdir.
  function session:path(rel)
    return self.tmpdir .. "/" .. rel
  end

  -- Send a `tmux send-keys` payload to the session. `payload` is the
  -- raw rest of the send-keys command, e.g. "Space t p" or
  -- "'literal text' Enter".
  function session:send_keys(payload)
    tmux_cmd(string.format("send-keys -t %s %s", self.name, payload))
  end

  function session:pane_count()
    local out = tmux_cmd(string.format(
      "list-panes -t %s -F '#{pane_id}'", self.name))
    if out == "" then return 0 end
    local n = 0
    for _ in out:gmatch("[^\n]+") do n = n + 1 end
    return n
  end

  function session:wait_for_pane_count(n, timeout_ms)
    return vim.wait(timeout_ms or 3000, function()
      return self:pane_count() == n
    end, 50)
  end

  -- start_nvim(opts):
  --   opts.init_lines  list of Lua source lines for the inner init
  --                    (default: paneity setup with leader=<Space>)
  --   opts.file        optional path for nvim to open
  --   opts.timeout_ms  ready-wait timeout (default 5000)
  --
  -- Launches `nvim --clean -u <init>` in the session's shell. The
  -- composed init writes a ready marker from `vim.schedule`, and this
  -- call BLOCKS until the marker appears. Raises on timeout.
  function session:start_nvim(nvim_opts)
    nvim_opts = nvim_opts or {}
    local init_lines = nvim_opts.init_lines or DEFAULT_INIT_LINES
    local timeout_ms = nvim_opts.timeout_ms or 5000

    local ready_marker = self:path("ready")
    local init_path    = self:path("init.lua")

    local composed = {}
    for _, line in ipairs(init_lines) do
      table.insert(composed, line)
    end
    table.insert(composed, "vim.schedule(function()")
    table.insert(composed, string.format(
      "  vim.fn.writefile({'ready'}, %q)", ready_marker))
    table.insert(composed, "end)")
    vim.fn.writefile(composed, init_path)

    local cmd = "nvim --clean -u " .. vim.fn.shellescape(init_path)
    if nvim_opts.file then
      cmd = cmd .. " " .. vim.fn.shellescape(nvim_opts.file)
    end
    self:send_keys(vim.fn.shellescape(cmd) .. " Enter")

    local ready = vim.wait(timeout_ms, function()
      return vim.fn.filereadable(ready_marker) == 1
    end, 50)
    assert(ready, string.format(
      "tmux_session: nvim did not signal readiness within %dms", timeout_ms))
  end

  function session:destroy()
    sh("tmux kill-server")
    if self.tmpdir and self.tmpdir ~= "" then
      sh("rm -rf " .. vim.fn.shellescape(self.tmpdir))
    end
    vim.env.TMUX_TMPDIR = nil
  end

  return session
end

return M
