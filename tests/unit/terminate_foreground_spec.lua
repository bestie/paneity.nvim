-- Unit tests for paneity._terminate_foreground.
--
-- Stubs the internal seams (`_pane_pid`, `_tty_foreground_pgid`, `_send_keys`,
-- `_kill`) so no real tmux/ps is required. Each test sets up a fake
-- foreground state and asserts which keys/kills were issued and what the
-- function returned.

describe("terminate_foreground (unit)", function()
  local paneity
  local sent_keys
  local kills

  -- queue(): each call returns the next value; sticks on the last value once
  -- exhausted. With step_timeout_ms=5 and the wait loop's interval=50,
  -- vim.wait polls twice per wait_for_shell call (immediate + at timeout).
  -- Plus one tpgid call at the top of _terminate_foreground (lazy clear)
  -- and one direct call in the TERM branch before the post-TERM wait.
  local function queue(values)
    local i = 0
    return function()
      i = i + 1
      return values[i] or values[#values]
    end
  end

  local function setup_stubs(pane_pid, tpgid_values)
    paneity._pane_pid = function() return pane_pid end
    paneity._tty_foreground_pgid = queue(tpgid_values)
  end

  before_each(function()
    package.loaded["paneity"] = nil
    paneity = require("paneity")
    paneity.setup({
      keybindings = false,
      termination = { step_timeout_ms = 5 },
    })
    sent_keys = {}
    kills = {}
    paneity._send_keys = function(_, key) table.insert(sent_keys, key) end
    paneity._kill = function(pid, sig) table.insert(kills, { pid = pid, sig = sig }) end
  end)

  it("returns true and sends no keys when shell is already foreground", function()
    setup_stubs(100, { 100 })
    paneity.last_paneity_command = "stale"

    local ok = paneity._terminate_foreground("%1", "echo new")

    assert.is_true(ok)
    assert.are.same({}, sent_keys)
    assert.are.same({}, kills)
    assert.is_nil(paneity.last_paneity_command)  -- lazy clear
  end)

  it("always sends C-c on first step, even when foreground is 'bash'", function()
    -- Simulates `bash my_script.sh`: pane root is bash (100), foreground is
    -- a child bash (200). Today's name check would skip; new behavior C-c's.
    -- C-c "succeeds" here (tpgid returns to 100 after).
    setup_stubs(100, { 200, 100 })

    local ok = paneity._terminate_foreground("%1", "echo new")

    assert.is_true(ok)
    assert.are.same({ "C-c" }, sent_keys)
  end)

  it("escalates to C-\\ when paneity owns the foreground", function()
    paneity.last_paneity_command = "prev"
    setup_stubs(100, { 200, 200, 200, 200, 100 })

    local ok = paneity._terminate_foreground("%1", "echo new")

    assert.is_true(ok)
    assert.are.same({ "C-c", "C-\\" }, sent_keys)
  end)

  it("does NOT escalate when paneity does not own the foreground", function()
    paneity.last_paneity_command = nil
    setup_stubs(100, { 200, 200, 200, 200 })

    local ok = paneity._terminate_foreground("%1", "echo new")

    assert.is_false(ok)
    assert.are.same({ "C-c" }, sent_keys)
    assert.are.same({}, kills)
  end)

  it("sends TERM when command matches and send_term is enabled", function()
    paneity.last_paneity_command = "make test"
    -- C-c, C-\\ both fail; TERM succeeds.
    setup_stubs(100, { 200, 200, 200, 200, 200, 200, 200, 100 })

    local ok = paneity._terminate_foreground("%1", "make test")

    assert.is_true(ok)
    assert.are.same({ "C-c", "C-\\" }, sent_keys)
    assert.are.same({ { pid = 200, sig = "TERM" } }, kills)
  end)

  it("does NOT send TERM when the new command does not match", function()
    paneity.last_paneity_command = "make test"
    setup_stubs(100, { 200, 200, 200, 200, 200 })

    local ok = paneity._terminate_foreground("%1", "make build")

    assert.is_false(ok)
    assert.are.same({ "C-c", "C-\\" }, sent_keys)
    assert.are.same({}, kills)
  end)

  it("does NOT send TERM when send_term is false", function()
    paneity.setup({
      keybindings = false,
      termination = { step_timeout_ms = 5, send_term = false },
    })
    sent_keys = {}; kills = {}
    paneity._send_keys = function(_, key) table.insert(sent_keys, key) end
    paneity._kill = function(pid, sig) table.insert(kills, { pid = pid, sig = sig }) end
    paneity.last_paneity_command = "make test"
    setup_stubs(100, { 200, 200, 200, 200, 200 })

    local ok = paneity._terminate_foreground("%1", "make test")

    assert.is_false(ok)
    assert.are.same({ "C-c", "C-\\" }, sent_keys)
    assert.are.same({}, kills)
  end)

  it("normalizes whitespace when comparing commands for TERM", function()
    paneity.last_paneity_command = "make test"
    setup_stubs(100, { 200, 200, 200, 200, 200, 200, 200, 100 })

    local ok = paneity._terminate_foreground("%1", "  make   test  ")

    assert.is_true(ok)
    assert.are.same({ { pid = 200, sig = "TERM" } }, kills)
  end)

  -- State-lifecycle tests carried over from Task 2 (still relevant).
  it("sets last_paneity_command when run is called", function()
    paneity._terminate_foreground = function() return true end
    local saved_popen = io.popen
    io.popen = function() return { read = function() return "" end, close = function() end } end
    paneity.target_pane_id = "%1"

    paneity.run("make test")

    io.popen = saved_popen
    assert.are.equal("make test", paneity.last_paneity_command)
  end)

  it("clears last_paneity_command when target pane changes", function()
    paneity.last_paneity_command = "make test"
    local saved_popen = io.popen
    io.popen = function() return { read = function() return "" end, close = function() end } end

    paneity.set_target_pane_id("%2")

    io.popen = saved_popen
    assert.is_nil(paneity.last_paneity_command)
    assert.are.equal("%2", paneity.target_pane_id)
  end)
end)
