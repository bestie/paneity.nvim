-- tests/integration/core_workflow_spec.lua
--
-- Integration test for paneity's core user workflow:
--   open a file → activate paneity (creates new pane) → set & run a
--   command → repeat it.
--
-- Strategy: a real nvim runs *inside* a tmux pane in an isolated tmux
-- server, and the test drives it entirely via `tmux send-keys`. No
-- paneity API is called from the test-runner nvim and no internal seams
-- are stubbed.
--
-- The generic mechanics (isolated tmux server, file I/O, polling,
-- launching nvim inside a tmux pane) are factored into helpers under
-- `tests/integration/support/`. The spec body adds a thin layer of
-- intention-revealing locals on top so each step of the workflow names
-- the user-facing action it drives.

local tmux_session = require("tests.integration.support.tmux_session")
local fs           = require("tests.integration.support.fs")
local wait         = require("tests.integration.support.wait")

describe("core workflow", function()
  local session
  local log_file

  before_each(function()
    session  = tmux_session.start({ name = "paneity_core_workflow" })
    log_file = session:path("cmd.log")
    session:start_nvim()
  end)

  after_each(function()
    session:destroy()
  end)

  local function activate_paneity()
    -- <leader>tp -> M.toggle -> M.set_target_pane -> choose_tmux_pane.
    -- Only one pane exists (excluding current), so the menu has just
    -- "New pane" and the UI is bypassed: open_new_pane runs.
    session:send_keys("Space t p")
    assert.is_true(session:wait_for_pane_count(2),
      "expected paneity to create a second pane within 3s")
  end

  local function set_and_run(command)
    -- <leader>tc -> M.new_command opens vim.ui.input. Type the
    -- command, then Enter -> M.run runs it in the paneity pane.
    session:send_keys("Space t c")
    session:send_keys(string.format("%s Enter", vim.fn.shellescape(command)))
  end

  local function repeat_last_command()
    -- <leader><leader> -> M.repeat_command -> M.run(M.previous_command).
    session:send_keys("Space Space")
  end

  local function wait_for_log_lines(n)
    assert.is_true(wait.until_true(function()
      return #fs.read_lines(log_file) >= n
    end, 5000), string.format("expected %d log line(s) within 5s", n))
  end

  it("activates paneity, runs a command, and repeats it", function()
    assert.are.equal(1, session:pane_count())

    activate_paneity()

    local token = fs.random_token()
    set_and_run(string.format("echo %s >> %s", token, log_file))
    wait_for_log_lines(1)
    assert.are.same({ token }, fs.read_lines(log_file))

    repeat_last_command()
    wait_for_log_lines(2)
    assert.are.same({ token, token }, fs.read_lines(log_file))
  end)
end)
