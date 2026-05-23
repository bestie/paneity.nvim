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

  before_each(function()
    tmux_tmpdir = trim(vim.fn.system("mktemp -d"))
    vim.env.TMUX_TMPDIR = tmux_tmpdir
  end)

  after_each(function()
    vim.fn.system("tmux kill-server")
    if tmux_tmpdir and tmux_tmpdir ~= "" then
      vim.fn.system("rm -rf " .. vim.fn.shellescape(tmux_tmpdir))
    end
    vim.env.TMUX_TMPDIR = nil
  end)

  it("activates paneity, runs a command, and repeats it", function()
    -- Filled in by subsequent tasks.
  end)
end)
