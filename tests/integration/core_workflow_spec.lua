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

  -- The default value of `M.defaults.marker`. Hardcoded rather than
  -- imported so the spec tests user-visible behavior (what shows up on
  -- the pane border) instead of coupling to module internals.
  local PANEITY_MARKER = "🥖🕹️"

  before_each(function()
    session  = tmux_session.start({ name = "paneity_core_workflow" })
    log_file = session:path("cmd.log")
    local REPO_ROOT = vim.fn.fnamemodify(
      vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h")
    local POPUP_HOME = REPO_ROOT .. "/tests/integration/support/popup_home"
    session:start_nvim({
      init_lines = {
        "vim.env.HOME = " .. string.format("%q", POPUP_HOME),
        "vim.env.XDG_DATA_HOME = " .. string.format("%q", session.tmpdir .. "/xdg"),
        string.format("vim.opt.runtimepath:prepend(%q)", REPO_ROOT),
        "vim.g.mapleader = ' '",
        "require('paneity').setup({})",
      },
    })
  end)

  after_each(function()
    session:destroy()
  end)

  local function activate_paneity()
    -- <leader>tp -> M.toggle -> M.set_target_pane -> choose_tmux_pane.
    -- Only one pane exists (excluding current), so the menu has just
    -- "New pane" and the UI is bypassed: open_new_pane runs. Returns
    -- the id of the new pane (the one that isn't the inner nvim's).
    session:send_keys("Space t p")
    assert.is_true(session:wait_for_pane_count(2),
      "expected paneity to create a second pane within 3s")
    for _, id in ipairs(session:pane_ids()) do
      if id ~= session.nvim_pane_id then
        return id
      end
    end
    error("could not find paneity target pane id")
  end

  local function set_and_run(command)
    -- <leader>tc -> M.new_command -> bash popup. Wait for the popup
    -- helper session to appear, clear the default prefill (Ctrl-A
    -- to move to BOL, Ctrl-K to kill to EOL), type the command,
    -- press Enter -> bash captures and exits -> popup closes ->
    -- M.run sends the command to the paneity pane.
    session:send_keys("Space t c")
    assert.is_true(session:wait_for_popup_session(),
      "expected popup session within 3s")
    assert.is_true(session:wait_for_popup_prompt(),
      "expected popup bash prompt within 5s")

    -- Clear any prefill, then type the command, then Enter.
    session:send_keys_to_popup("C-a C-k")
    session:send_keys_to_popup(string.format("%s Enter",
      vim.fn.shellescape(command)))

    assert.is_true(session:wait_for_no_popup_session(),
      "expected popup session to close after Enter within 3s")
  end

  local function repeat_last_command()
    -- <leader><leader> -> M.repeat_command -> M.run(M.previous_command).
    session:send_keys("Space Space")
  end

  local function quit_nvim()
    -- Escape guards against being in cmdline/insert mode from a prior
    -- step; :qa! exits unconditionally so VimLeave fires the cleanup
    -- autocmd that unmarks the target pane.
    session:send_keys("Escape : q a ! Enter")
  end

  local function wait_for_log_lines(n)
    assert.is_true(wait.until_true(function()
      return #fs.read_lines(log_file) >= n
    end, 5000), string.format("expected %d log line(s) within 5s", n))
  end

  it("activates paneity, runs a command, and repeats it", function()
    assert.are.equal(1, session:pane_count())

    local target = activate_paneity()

    -- paneity stamps its marker into the target pane's
    -- pane-border-format so users can see which pane is wired up.
    local border = session:pane_border_format(target)
    assert.is_truthy(border:find(PANEITY_MARKER, 1, true),
      "expected marker in pane-border-format; got: " .. border)

    local token = fs.random_token()
    set_and_run(string.format("echo %s >> %s", token, log_file))
    wait_for_log_lines(1)
    assert.are.same({ token }, fs.read_lines(log_file))

    repeat_last_command()
    wait_for_log_lines(2)
    assert.are.same({ token, token }, fs.read_lines(log_file))

    quit_nvim()

    -- VimLeave runs unmark_pane on the target, restoring the
    -- per-pane pane-border-format to the marker-less global value.
    assert.is_true(wait.until_true(function()
      return not session:pane_border_format(target):find(PANEITY_MARKER, 1, true)
    end, 3000),
      "expected marker to be removed from pane-border-format after nvim quits; " ..
      "got: " .. session:pane_border_format(target))
  end)
end)
