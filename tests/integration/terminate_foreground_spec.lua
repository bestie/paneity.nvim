-- tests/integration/terminate_foreground_spec.lua
--
-- Integration tests for paneity's foreground-termination behavior:
-- the C-c → C-\\ → kill -TERM escalation ladder, and the UI prompt
-- that fires when the ladder gives up.
--
-- Strategy mirrors `core_workflow_spec`: a real nvim runs *inside* a
-- tmux pane in an isolated tmux server, and each spec drives it via
-- `tmux send-keys` against paneity's documented keybindings. No
-- paneity API is called from the test-runner nvim; the only direct
-- tmux send-keys against the *target* pane are used to start
-- processes paneity itself did NOT launch (i.e. to exercise the
-- ownership gate).
--
-- Generic plumbing (isolated tmux server, file I/O, polling,
-- launching nvim inside a tmux pane) lives in
-- `tests/integration/support/`.

local tmux_session = require("tests.integration.support.tmux_session")
local fs           = require("tests.integration.support.fs")
local wait         = require("tests.integration.support.wait")

describe("terminate_foreground", function()
  local session
  local log_file
  local signals_log

  before_each(function()
    session     = tmux_session.start({ name = "paneity_terminate_foreground" })
    log_file    = session:path("cmd.log")
    signals_log = session:path("signals.log")
  end)

  after_each(function()
    session:destroy()
  end)

  local function activate_paneity()
    -- <leader>tp -> M.toggle -> M.set_target_pane -> choose_tmux_pane.
    -- With only the nvim pane in the session, the menu collapses to
    -- "New pane" and open_new_pane runs. Returns the new pane's id
    -- (the one that isn't the inner nvim's pane).
    session:send_keys("Space t p")
    assert.is_true(session:wait_for_pane_count(2),
      "expected paneity to create a target pane within 3s")
    for _, id in ipairs(session:pane_ids()) do
      if id ~= session.nvim_pane_id then
        return id
      end
    end
    error("could not find paneity target pane id")
  end

  local function set_and_run(command)
    session:send_keys("Space t c")
    session:send_keys(string.format("%s Enter", vim.fn.shellescape(command)))
  end

  local function wait_for_log_lines(path, n)
    return wait.until_true(function()
      return #fs.read_lines(path) >= n
    end, 5000)
  end

  local function wait_for_log_content(path, needle)
    return wait.until_true(function()
      for _, line in ipairs(fs.read_lines(path)) do
        if line:find(needle, 1, true) then return true end
      end
      return false
    end, 3000)
  end

  it("sends SIGINT to a foreground blocker then runs the new command", function()
    session:start_nvim()
    local target = activate_paneity()

    -- Start the blocker via tmux directly, NOT through paneity. This
    -- keeps M.last_paneity_command nil — step 1's C-c must still land
    -- (always-C-c contract); since sleep responds to SIGINT, the
    -- ladder does not need to escalate past the gate.
    session:send_keys_to(target, "'sleep 30' Enter")
    assert.is_true(wait.until_true(function()
      return session:pane_current_command(target) == "sleep"
    end, 2000), "expected pane_current_command to become 'sleep' within 2s")

    local token = fs.random_token()
    set_and_run(string.format("echo %s >> %s", token, log_file))

    assert.is_true(wait_for_log_lines(log_file, 1),
      "expected the new command to land after C-c killed the blocker")
    assert.are.same({ token }, fs.read_lines(log_file))
  end)

  it("escalates to SIGQUIT when the foreground process ignores SIGINT", function()
    session:start_nvim()
    activate_paneity()

    -- A Lua script run via `nvim -l` keeps a libuv loop alive that
    -- records signals. We have *paneity* run the blocker (via
    -- <leader>tc), which sets M.last_paneity_command and so opens the
    -- ownership gate for the next run's escalation.
    local blocker = session:path("blocker.lua")
    fs.write(blocker, {
      "local sig_log = arg[1]",
      "local function write(name)",
      "  local f = io.open(sig_log, 'a')",
      "  f:write(name .. '\\n')",
      "  f:close()",
      "end",
      "local sigint = vim.uv.new_signal()",
      "sigint:start('sigint', function() write('SIGINT') end)",
      "local sigquit = vim.uv.new_signal()",
      "sigquit:start('sigquit', function() write('SIGQUIT'); os.exit(0) end)",
      "write('READY')",
      "vim.uv.run()",
    })
    set_and_run(string.format("nvim -l %s %s", blocker, signals_log))
    assert.is_true(wait_for_log_content(signals_log, "READY"),
      "expected blocker to write READY within 3s")

    local token = fs.random_token()
    set_and_run(string.format("echo %s >> %s", token, log_file))

    assert.is_true(wait_for_log_lines(log_file, 1),
      "expected the new command to land after SIGQUIT escalation")
    assert.are.same({ token }, fs.read_lines(log_file))
    assert.are.same({ "READY", "SIGINT", "SIGQUIT" }, fs.read_lines(signals_log))
  end)

  it("sends C-c, blocks escalation, and prompts when paneity didn't start the foreground process", function()
    -- The prompt opens via `vim.fn.confirm` inside the *inner* nvim,
    -- so we stub _prompt_termination_choice via extra_init_lines.
    -- The stub flags a marker file (so the test can observe that the
    -- prompt was invoked) and returns "cancel" so the new command is
    -- skipped.
    local prompt_marker = session:path("prompted")
    session:start_nvim({
      extra_init_lines = {
        "require('paneity')._prompt_termination_choice = function()",
        string.format("  vim.fn.writefile({'prompted'}, %q)", prompt_marker),
        "  return 'cancel'",
        "end",
      },
    })
    local target = activate_paneity()

    -- The QUIT trap is load-bearing: bash would otherwise exit
    -- silently on SIGQUIT (default disposition), masking a regression
    -- where the gate wrongly lets escalation through. With the trap,
    -- the strict `{ "READY", "SIGINT" }` assertion catches it.
    local script = session:path("script.sh")
    fs.write(script, {
      'log="$1"',
      [[trap 'echo SIGINT >> "$log"' INT]],
      [[trap 'echo SIGQUIT >> "$log"' QUIT]],
      'echo READY >> "$log"',
      'while true; do read line; done',
    })

    -- Script started by tmux directly: paneity did NOT run it, so
    -- M.last_paneity_command stays nil and the gate must block
    -- escalation past step 1.
    session:send_keys_to(target,
      string.format("'bash %s %s' Enter", script, signals_log))
    assert.is_true(wait_for_log_content(signals_log, "READY"),
      "expected script to write READY within 3s")
    assert.are.equal("bash", session:pane_current_command(target),
      "precondition: pane_current_command should be 'bash' " ..
      "(indistinguishable from an idle interactive shell)")

    local token = fs.random_token()
    set_and_run(string.format("echo %s >> %s", token, log_file))

    -- C-c lands (SIGINT trap fires), gate blocks escalation, prompt
    -- is invoked (marker appears).
    assert.is_true(wait_for_log_content(signals_log, "SIGINT"),
      "expected SIGINT in signals log within 3s")
    assert.is_true(wait.until_true(function()
      return fs.exists(prompt_marker)
    end, 2000), "expected the prompt to be invoked (marker file)")

    -- No SIGQUIT, and "cancel" means the new command was never sent.
    assert.are.same({ "READY", "SIGINT" }, fs.read_lines(signals_log))
    assert.are.same({}, fs.read_lines(log_file))
  end)
end)
