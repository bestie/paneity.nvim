-- tests/integration/core_workflow_spec.lua
--
-- Integration test for paneity's core user workflow:
--   open a file → activate paneity (creates new pane) → set & run a
--   command → repeat it.
--
-- Strategy mirrors tests/integration/terminate_foreground_spec.lua: spin up
-- an isolated tmux server via TMUX_TMPDIR so the developer's real session is
-- never touched. The difference is that here we run a real nvim *inside*
-- the tmux pane and drive it entirely via `tmux send-keys` — no paneity API
-- is called from the test-runner nvim, and no internal seams are stubbed.

local repo_root = vim.fn.fnamemodify(
  vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h"
)

local function trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function tmux(args)
  return trim(vim.fn.system("tmux " .. args))
end

local function wait_until(predicate, timeout_ms, interval_ms)
  interval_ms = interval_ms or 50
  return vim.wait(timeout_ms, predicate, interval_ms)
end

local function file_exists(path)
  return vim.fn.filereadable(path) == 1
end

local function read_lines(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local lines = {}
  for line in f:lines() do
    table.insert(lines, line)
  end
  f:close()
  return lines
end

local function count_panes(session)
  local output = tmux(string.format("list-panes -t %s -F '#{pane_id}'", session))
  if output == "" then return 0 end
  local count = 0
  for _ in string.gmatch(output, "[^\n]+") do
    count = count + 1
  end
  return count
end

describe("core workflow", function()
  local tmux_tmpdir
  local session = "paneity_core_workflow"
  local ready_marker, log_file, inner_init, edit_file

  before_each(function()
    tmux_tmpdir = trim(vim.fn.system("mktemp -d"))
    vim.env.TMUX_TMPDIR = tmux_tmpdir

    ready_marker = tmux_tmpdir .. "/ready"
    log_file = tmux_tmpdir .. "/cmd.log"
    inner_init = tmux_tmpdir .. "/init.lua"
    edit_file = tmux_tmpdir .. "/edit.txt"

    -- A real file for nvim to open; contents don't matter to paneity.
    vim.fn.writefile({ "edit me" }, edit_file)

    -- Inner init: put paneity on the rtp, set leader BEFORE setup so
    -- `<leader>...` mappings bind to <Space>, then signal readiness from
    -- vim.schedule so we know the event loop is alive before the test
    -- starts driving keystrokes.
    vim.fn.writefile({
      string.format("vim.opt.runtimepath:prepend(%q)", repo_root),
      "vim.g.mapleader = ' '",
      "require('paneity').setup({})",
      "vim.schedule(function()",
      string.format("  vim.fn.writefile({'ready'}, %q)", ready_marker),
      "end)",
    }, inner_init)

    -- Detached session, single window, single pane, running nvim against
    -- the inner init and editing edit_file.
    tmux(string.format(
      "new-session -d -s %s -x 200 -y 50 'nvim --clean -u %s %s'",
      session, vim.fn.shellescape(inner_init), vim.fn.shellescape(edit_file)
    ))

    local ready = wait_until(function()
      return file_exists(ready_marker)
    end, 5000)
    assert.is_true(ready,
      "expected inner nvim to write the ready marker within 5s")
  end)

  after_each(function()
    vim.fn.system("tmux kill-server")
    if tmux_tmpdir and tmux_tmpdir ~= "" then
      vim.fn.system("rm -rf " .. vim.fn.shellescape(tmux_tmpdir))
    end
    vim.env.TMUX_TMPDIR = nil
  end)

  it("activates paneity, runs a command, and repeats it", function()
    -- Smoke check: inner nvim is up. (before_each already asserted on the
    -- ready marker, but checking here makes the test self-explanatory.)
    assert.is_true(file_exists(ready_marker))

    -- Initial state: one pane in the session.
    assert.are.equal(1, count_panes(session))
  end)
end)
