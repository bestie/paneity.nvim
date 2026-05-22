# Robust foreground-process termination — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace name-based shell detection with tty foreground-pgrp comparison; gate escalation on paneity-ownership and command-match; add a UI prompt for the unrecoverable case.

**Architecture:** Add three new internal seams (`_pane_pid`, `_tty_foreground_pgid`, `_kill`) and a `_prompt_termination_choice` seam, all stubbable for unit tests. Replace `_terminate_foreground` with a new ladder driven by `shell_is_foreground` (PID comparison), gated on `M.last_paneity_command` state. `M.run` handles the UI prompt branch when termination fails.

**Tech Stack:** Lua, Neovim, tmux, plenary.nvim (testing). Tests run under headless mise-managed Neovim via `make test`.

**Spec:** `docs/superpowers/specs/2026-05-12-robust-shell-detection-design.md`

**Branch:** `fg-quit-no-kill` (already checked out)

---

## File map

- **Modify:** `lua/paneity/init.lua` — all behavior changes live here.
- **Modify:** `tests/unit/terminate_foreground_spec.lua` — rewrite for new ladder semantics.
- **Modify:** `tests/integration/terminate_foreground_spec.lua` — update SIGQUIT test, flip known-limitation test.
- **Modify:** `README.md` — document new `termination` config table.
- **Modify:** `TODO.md` — strike the "Name-based shell detection misses `bash my_script.sh`" entry.

No new files.

---

## Task 1: Add scaffolding — seams, helper, config defaults

Pure additions. No behavior change yet — `_terminate_foreground` still uses the old name-based code at the end of this task. Tests still pass.

**Files:**
- Modify: `lua/paneity/init.lua`

- [ ] **Step 1: Add `termination` defaults to `M.defaults`**

In `lua/paneity/init.lua`, find the `M.defaults` table (around line 380). Add a `termination` sub-table:

```lua
M.defaults = {
  log_level = vim.log.levels.OFF,
  marker = "🥖🕹️",
  split_direction = nil,
  split_size = nil,
  split_percentage_size = nil,
  termination = {
    key_sequence    = { "C-c", "C-\\" },
    send_term       = true,
    step_timeout_ms = 200,
  },
  keybindings = {
    toggle = "<leader>tp",
    repeat_command = "<leader><leader>",
    new_command = "<leader>tc",
    page_up = "<PageUp>",
    page_down = "<PageDown>",
    up_enter = "<leader><Up>",
  }
}
```

- [ ] **Step 2: Add new internal seams**

In `lua/paneity/init.lua`, near the existing seams (after `M._send_keys` around line 77), add:

```lua
function M._pane_pid(pane_id)
  local output = shell_exec(string.format("tmux display -p -t %s '#{pane_pid}'", pane_id))
  return tonumber(output)
end

function M._tty_foreground_pgid(pane_pid)
  local output = shell_exec(string.format("ps -o tpgid= -p %s", pane_pid))
  return tonumber(output)
end

function M._kill(pid, signal)
  shell_exec(string.format("kill -%s %s", signal, pid))
end
```

- [ ] **Step 3: Add `shell_is_foreground` and `normalize_command` private helpers**

In `lua/paneity/init.lua`, add these as local (non-exported) helpers, placed after the seams from Step 2:

```lua
local function shell_is_foreground(pane_id)
  local pane_pid = M._pane_pid(pane_id)
  if not pane_pid then return false end
  local tpgid = M._tty_foreground_pgid(pane_pid)
  return tpgid ~= nil and tpgid == pane_pid
end

local function normalize_command(command)
  if command == nil then return nil end
  return (command:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1"))
end
```

- [ ] **Step 4: Add `_prompt_termination_choice` seam**

In `lua/paneity/init.lua`, near the other internal seams, add:

```lua
function M._prompt_termination_choice()
  local choice = vim.fn.confirm(
    "Paneity: foreground didn't respond. Type anyway, cancel, or kill -TERM?",
    "&Type anyway\n&Cancel\nkill -&TERM",
    2  -- default: Cancel
  )
  if choice == 1 then return "type"
  elseif choice == 3 then return "term"
  else return "cancel" end
end
```

- [ ] **Step 5: Run the full test suite to verify nothing broke**

Run: `make test`
Expected: All 6 tests still pass (3 unit + 3 integration). We've only added code, not removed any.

- [ ] **Step 6: Commit**

```bash
git add lua/paneity/init.lua
git commit -m "Add seams, helper, and termination config defaults"
```

---

## Task 2: Track `last_paneity_command` state

Adds the state that the new ladder will gate on. Still no behavior change — the state is set/cleared but not yet read by `_terminate_foreground`.

**Files:**
- Modify: `lua/paneity/init.lua`
- Modify: `tests/unit/terminate_foreground_spec.lua` (new test for state lifecycle)

- [ ] **Step 1: Initialize `last_paneity_command` in `setup`**

In `lua/paneity/init.lua`, find `M.setup` (around line 437). Add a line beside `M.previous_command = M.previous_command or ""`:

```lua
function M.setup(user_config)
  -- retain some state
  M.target_pane_id = M.target_pane_id or nil
  M.previous_command = M.previous_command or ""
  M.last_paneity_command = M.last_paneity_command or nil
  -- ... rest unchanged
```

- [ ] **Step 2: Clear `last_paneity_command` when target changes**

In `lua/paneity/init.lua`, find `M.set_target_pane_id` (around line 192). Add the clear:

```lua
M.set_target_pane_id = function(pane_id)
  M.target_pane_id = pane_id
  M.last_paneity_command = nil
  mark_pane(M.target_pane_id, M.config.marker)
end
```

- [ ] **Step 3: Set `last_paneity_command` in `M.run`**

In `lua/paneity/init.lua`, find `M.run` (around line 290). Update it to record the command:

```lua
function M.run(command)
  send_to_tmux_pane(M.target_pane_id, command)
  M.previous_command = command
  M.last_paneity_command = command
end
```

- [ ] **Step 4: Write a unit test for the state lifecycle**

Add to `tests/unit/terminate_foreground_spec.lua`, inside the `describe` block (just append a new `it`):

```lua
  it("sets last_paneity_command when run is called", function()
    -- Stub send_to_tmux_pane's dependencies so run() doesn't hit real tmux.
    paneity._terminate_foreground = function() return true end
    paneity._send_keys = function(_, _) end
    -- Suppress the actual send_command shell_exec by stubbing the seam it uses;
    -- send_command isn't a seam, but it goes through shell_exec which is internal.
    -- Easiest: stub `M.run` indirectly by replacing the send_command path. Use
    -- the fact that send_to_tmux_pane only calls _terminate_foreground and then
    -- send_command (which calls shell_exec). Override `io.popen` for this test.
    local saved_popen = io.popen
    io.popen = function() return { read = function() return "" end, close = function() end } end
    paneity.target_pane_id = "%1"

    paneity.run("make test")

    io.popen = saved_popen
    assert.are.equal("make test", paneity.last_paneity_command)
  end)

  it("clears last_paneity_command when target pane changes", function()
    paneity.last_paneity_command = "make test"
    -- Stub mark_pane's tmux calls via io.popen.
    local saved_popen = io.popen
    io.popen = function() return { read = function() return "" end, close = function() end } end

    paneity.set_target_pane_id("%2")

    io.popen = saved_popen
    assert.is_nil(paneity.last_paneity_command)
  end)
```

- [ ] **Step 5: Run the tests to verify the new ones pass**

Run: `make test`
Expected: 5 unit tests + 3 integration tests pass (3 old unit + 2 new unit + 3 integration).

- [ ] **Step 6: Commit**

```bash
git add lua/paneity/init.lua tests/unit/terminate_foreground_spec.lua
git commit -m "Track last_paneity_command across runs and target changes"
```

---

## Task 3: Rewrite `_terminate_foreground` with the new ladder

This is the main behavior change. Drop SHELLS/REPLS, always send C-c, gate escalation, return bool. Rewrites the unit test file. Updates the SIGQUIT integration test (blocker must now be started via `paneity.run` to satisfy the gate).

**Files:**
- Modify: `lua/paneity/init.lua`
- Modify: `tests/unit/terminate_foreground_spec.lua`
- Modify: `tests/integration/terminate_foreground_spec.lua`

- [ ] **Step 1: Rewrite the unit test file**

Replace the entire contents of `tests/unit/terminate_foreground_spec.lua` with:

```lua
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

  -- queue(): each call returns the next value; sticks on the last value
  -- once exhausted. Mirrors the wait-loop polling shape.
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
    setup_stubs(100, { 200, 200, 100 })

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
    setup_stubs(100, { 200, 200, 200, 200, 200, 100 })

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
    setup_stubs(100, { 200, 200, 200, 200, 200, 100 })

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
  end)
end)
```

- [ ] **Step 2: Run unit tests to verify they FAIL**

Run: `make test`
Expected: The new behavior-shape tests fail (e.g. "always sends C-c on first step, even when foreground is 'bash'"). The old `_terminate_foreground` still uses the SHELLS check. This proves the tests exercise the right thing.

- [ ] **Step 3: Rewrite `_terminate_foreground` in `lua/paneity/init.lua`**

In `lua/paneity/init.lua`, replace lines 66-102 (the `SHELLS`/`REPLS` tables, `wait_for_shell`, and the old `_terminate_foreground`) with:

```lua
local function wait_for_shell(pane_id, timeout_ms)
  return vim.wait(timeout_ms, function()
    return shell_is_foreground(pane_id)
  end, 50)
end

function M._terminate_foreground(pane_id, new_command)
  local termination = M.config.termination

  -- Lazy clear: if the shell is already foreground, no paneity command is
  -- currently running. Nothing to terminate.
  if shell_is_foreground(pane_id) then
    M.last_paneity_command = nil
    return true
  end

  local key_sequence = termination.key_sequence

  -- Step 1: always send the first key (C-c by default). Harmless at an idle
  -- prompt, clears any partial command, interrupts running processes.
  M._send_keys(pane_id, key_sequence[1])
  if wait_for_shell(pane_id, termination.step_timeout_ms) then
    M.last_paneity_command = nil
    return true
  end

  -- Gate: don't escalate against processes paneity didn't start.
  if not M.last_paneity_command then
    return false
  end

  -- Step 2: remaining keys in the sequence (gated on paneity ownership).
  for i = 2, #key_sequence do
    M._send_keys(pane_id, key_sequence[i])
    if wait_for_shell(pane_id, termination.step_timeout_ms) then
      M.last_paneity_command = nil
      return true
    end
  end

  -- Step 3: TERM the foreground process group. Doubly gated:
  -- (a) send_term must be enabled, (b) the new command must match the last
  -- paneity-issued command (after whitespace normalization).
  if termination.send_term and new_command
     and normalize_command(new_command) == normalize_command(M.last_paneity_command) then
    local pane_pid = M._pane_pid(pane_id)
    local tpgid = M._tty_foreground_pgid(pane_pid)
    if tpgid and tpgid ~= pane_pid then
      M._kill(tpgid, "TERM")
      if wait_for_shell(pane_id, termination.step_timeout_ms) then
        M.last_paneity_command = nil
        return true
      end
    end
  end

  return false
end
```

Also update the caller at `send_to_tmux_pane` (around line 104) so it ignores the return value — `M.run` will handle the prompt in Task 4. For now:

```lua
local function send_to_tmux_pane(target_pane_id, command)
  M._terminate_foreground(target_pane_id, command)
  send_command(target_pane_id, command)
end
```

- [ ] **Step 4: Run unit tests to verify they PASS**

Run: `make test`
Expected: All unit tests pass. Integration "SIGQUIT escalation" test still fails (it needs Step 5's update — blocker must be paneity-owned for the gate).

- [ ] **Step 5: Update the SIGQUIT integration test**

In `tests/integration/terminate_foreground_spec.lua`, find the "escalates to SIGQUIT" test (around line 84). Make two changes:

(a) Change how the blocker is started — from raw tmux send-keys to `paneity.run` so paneity owns the foreground:

Replace:
```lua
    tmux(string.format("send-keys -t %s 'nvim -l %s %s' C-m",
      pane_id, script_path, sig_log))
```
With:
```lua
    require("paneity").run(string.format("nvim -l %s %s", script_path, sig_log))
```

(b) Update the expected log. The new ladder sends C-c once (not twice), so:

Replace:
```lua
    assert.are.same({ "READY", "SIGINT", "SIGINT", "SIGQUIT" }, lines)
```
With:
```lua
    assert.are.same({ "READY", "SIGINT", "SIGQUIT" }, lines)
```

The dedup comment in the script body becomes irrelevant but harmless; leave it.

- [ ] **Step 6: Run the full suite**

Run: `make test`
Expected: All unit tests pass. SIGINT happy-path and SIGQUIT escalation integration tests pass. The "bash my_script.sh known limitation" test STILL passes as-is — `paneity.run` calls `vim.fn.confirm` (because the gate blocks escalation against the user-launched script, so `_terminate_foreground` returns false). Wait — that means the prompt fires, which blocks headlessly. This will hang.

**If the bash test hangs:** that's expected — `M.run` will get a UI prompt added in Task 4, and the bash test will be updated in Task 5 to stub it. For now, temporarily skip that test by changing `it(...)` to `pending(...)` on the bash test:

Find:
```lua
  it("does NOT terminate `bash my_script.sh` because pane_current_command is just 'bash' (known limitation)", function()
```
Change to:
```lua
  pending("does NOT terminate `bash my_script.sh` because pane_current_command is just 'bash' (known limitation)", function()
```

(`pending` is plenary-busted's skip mechanism — the test body is parsed but not executed.)

Re-run `make test`. Expected: 8 unit tests pass, 2 integration tests pass, 1 pending.

- [ ] **Step 7: Commit**

```bash
git add lua/paneity/init.lua tests/unit/terminate_foreground_spec.lua tests/integration/terminate_foreground_spec.lua
git commit -m "Rewrite _terminate_foreground with PID-based detection and gated escalation"
```

---

## Task 4: Add UI prompt branch in `M.run`

When `_terminate_foreground` returns false, prompt the user via `vim.fn.confirm` (already wrapped in `M._prompt_termination_choice` from Task 1). Handle the three branches: type anyway, cancel, kill -TERM.

**Files:**
- Modify: `lua/paneity/init.lua`
- Modify: `tests/unit/terminate_foreground_spec.lua`

- [ ] **Step 1: Add unit tests for the three prompt branches**

Append to `tests/unit/terminate_foreground_spec.lua`, inside the same `describe` block:

```lua
  describe("run with UI prompt fallback", function()
    local sent_commands

    before_each(function()
      sent_commands = {}
      paneity.target_pane_id = "%1"
      -- Stub the shell_exec call inside send_command (no real tmux).
      local saved_popen = io.popen
      io.popen = function(cmd)
        if cmd:match("send%-keys.*C%-m") then
          table.insert(sent_commands, cmd)
        end
        return { read = function() return "" end, close = function() end }
      end
      paneity._restore_popen = function() io.popen = saved_popen end
    end)

    after_each(function()
      paneity._restore_popen()
    end)

    it("does not send the command when the user picks Cancel", function()
      paneity._terminate_foreground = function() return false end
      paneity._prompt_termination_choice = function() return "cancel" end

      paneity.run("echo X")

      assert.are.same({}, sent_commands)
    end)

    it("sends the command when the user picks Type anyway", function()
      paneity._terminate_foreground = function() return false end
      paneity._prompt_termination_choice = function() return "type" end

      paneity.run("echo X")

      assert.is_true(#sent_commands == 1, "expected one send-keys call")
    end)

    it("issues kill -TERM and sends the command when the user picks TERM", function()
      paneity._terminate_foreground = function() return false end
      paneity._prompt_termination_choice = function() return "term" end
      paneity._pane_pid = function() return 100 end
      paneity._tty_foreground_pgid = function() return 200 end
      kills = {}
      paneity._kill = function(pid, sig) table.insert(kills, { pid = pid, sig = sig }) end

      paneity.run("echo X")

      assert.are.same({ { pid = 200, sig = "TERM" } }, kills)
      assert.is_true(#sent_commands == 1, "expected the command to be sent after TERM")
    end)
  end)
```

- [ ] **Step 2: Run tests to verify they FAIL**

Run: `make test`
Expected: The three new tests fail. Cancel test fails because `M.run` currently always sends. Type test passes accidentally. TERM test fails because there's no kill issued.

- [ ] **Step 3: Update `M.run` to handle the prompt branches**

In `lua/paneity/init.lua`, replace `M.run` (around line 290) with:

```lua
function M.run(command)
  local pane_id = M.target_pane_id
  local ok = M._terminate_foreground(pane_id, command)

  if not ok then
    local choice = M._prompt_termination_choice()
    if choice == "cancel" then
      return
    elseif choice == "term" then
      local pane_pid = M._pane_pid(pane_id)
      local tpgid = M._tty_foreground_pgid(pane_pid)
      if tpgid and tpgid ~= pane_pid then
        M._kill(tpgid, "TERM")
        wait_for_shell(pane_id, M.config.termination.step_timeout_ms)
      end
    end
    -- "type" falls through: send the command into whatever's there.
  end

  send_command(pane_id, command)
  M.previous_command = command
  M.last_paneity_command = command
end
```

Note: `send_to_tmux_pane` is no longer called by `M.run`; it's now redundant. Delete the `send_to_tmux_pane` function (lines around 104-107) — verify with grep first:

```bash
grep -n "send_to_tmux_pane" lua/paneity/init.lua
```

Expected: only the definition and the (now-removed) reference in `M.run`. If anything else references it, leave it; if not, delete the function definition.

- [ ] **Step 4: Run unit tests to verify they pass**

Run: `make test`
Expected: All unit tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/paneity/init.lua tests/unit/terminate_foreground_spec.lua
git commit -m "Surface UI prompt when foreground refuses to terminate"
```

---

## Task 5: Un-pend and update the bash my_script.sh integration test

Now that the prompt branch exists, the bash-script test can stub it and assert the new behavior: C-c IS sent (SIGINT logged), gate blocks escalation, prompt is invoked.

**Files:**
- Modify: `tests/integration/terminate_foreground_spec.lua`

- [ ] **Step 1: Update the bash my_script.sh test**

In `tests/integration/terminate_foreground_spec.lua`, find the `pending(...)` block from Task 3 Step 6. Replace the test header AND body:

Find:
```lua
  pending("does NOT terminate `bash my_script.sh` because pane_current_command is just 'bash' (known limitation)", function()
```

Replace with:
```lua
  it("sends C-c to a foreground bash script and prompts when gate blocks escalation", function()
```

Then in the test body, replace the final assertion block. The body currently ends with:

```lua
    require("paneity").run("echo PANEITY_BUG")

    vim.wait(500)

    -- No signals were ever sent — the trap log only contains READY.
    local lines = {}
    for line in read_log():gmatch("[^\n]+") do
      table.insert(lines, line)
    end
    assert.are.same({ "READY" }, lines)
  end)
```

Replace with:
```lua
    -- Stub the prompt to choose Cancel (no command will be sent).
    local prompted = false
    require("paneity")._prompt_termination_choice = function()
      prompted = true
      return "cancel"
    end

    require("paneity").run("echo PANEITY_OK")

    vim.wait(500)

    -- C-c WAS sent (SIGINT trap fired). The gate blocked escalation since
    -- paneity didn't start the script. The prompt was invoked.
    local lines = {}
    for line in read_log():gmatch("[^\n]+") do
      table.insert(lines, line)
    end
    assert.are.same({ "READY", "SIGINT" }, lines)
    assert.is_true(prompted, "expected the UI prompt to be invoked")

    -- And the new command was NOT sent (user picked Cancel).
    local pane_content = capture_pane(pane_id)
    assert.is_nil(pane_content:find("PANEITY_OK", 1, true),
      "expected PANEITY_OK not to appear; got:\n" .. pane_content)
  end)
```

- [ ] **Step 2: Run the full suite**

Run: `make test`
Expected: All 11 unit tests pass + 3 integration tests pass. No `pending` skips.

- [ ] **Step 3: Commit**

```bash
git add tests/integration/terminate_foreground_spec.lua
git commit -m "Flip bash my_script.sh test: gate blocks escalation, prompt fires"
```

---

## Task 6: Documentation and TODO cleanup

Document the new `termination` config in README.md and strike the resolved item from TODO.md.

**Files:**
- Modify: `README.md`
- Modify: `TODO.md`

- [ ] **Step 1: Read the relevant README section**

Run: `grep -n -A 5 "setup\|config" README.md | head -80`

Identify where existing configuration options are documented (probably in a setup example or a "Configuration" section).

- [ ] **Step 2: Add `termination` documentation to README**

In `README.md`, locate the configuration/setup section. Add a `termination` block to the example config, matching the style of existing options. Suggested addition:

````markdown
### Termination

Before running a new command, paneity sends C-c to the target pane to clear any partial command line or interrupt a running process. If the foreground process doesn't return to a shell, paneity may escalate — but only for commands paneity itself started, and only as far as you allow.

```lua
require("paneity").setup({
  termination = {
    -- send-keys ladder. The first entry is always sent (harmless at an idle
    -- prompt). Subsequent entries are sent only if paneity issued the
    -- previous command in this pane.
    key_sequence    = { "C-c", "C-\\" },

    -- After the key_sequence is exhausted, send `kill -TERM` to the
    -- foreground process group. Doubly gated: requires paneity ownership AND
    -- the new command must match the previous (you're re-running the same
    -- thing — replacing it is fine). Disable if you run docker-style wrappers
    -- where TERM kills the host-side CLI but leaves the container orphaned.
    send_term       = true,

    -- Time to wait between each escalation step for the shell to return.
    step_timeout_ms = 200,
  },
})
```

If all permitted escalation fails to return the pane to a shell prompt, paneity asks what to do: type the new command anyway, cancel, or fall back to `kill -TERM`.
````

- [ ] **Step 3: Strike the resolved item in TODO.md**

In `TODO.md`, find the "Robustness" section heading and the "Name-based shell detection misses `bash my_script.sh`" item underneath. Delete the entire bulleted item (the heading `### Name-based shell detection misses \`bash my_script.sh\`` and its body, through the next `###` or section break).

- [ ] **Step 4: Run the test suite one final time**

Run: `make test`
Expected: All tests pass (no doc changes affect tests, but the discipline pays off — confirms nothing regressed).

- [ ] **Step 5: Commit**

```bash
git add README.md TODO.md
git commit -m "Document termination config and strike resolved TODO"
```

---

## Self-review

### Spec coverage
- Detection via tty foreground-pgrp → Task 1 (seam + helper), Task 3 (consumed).
- Always-C-c step → Task 3.
- Gated escalation key → Task 3.
- Doubly-gated TERM → Task 3.
- UI prompt fallback → Task 4.
- State (last_paneity_command, lazy clear, target-change clear) → Task 2.
- Config surface (`termination` table) → Task 1.
- Module surface changes (new/changed/removed seams) → Task 1 (adds), Task 3 (removes SHELLS/REPLS).
- Integration test flip → Task 5.
- Migration / compat note (README docs) → Task 6.

All spec sections covered.

### Placeholder scan
None — every code/test/command step contains the actual content.

### Type consistency
- `_terminate_foreground(pane_id, new_command) → bool` consistent in Task 3 (definition) and Task 4 (caller).
- `_prompt_termination_choice() → "type" | "cancel" | "term"` consistent in Task 1 (definition) and Task 4 (caller / tests).
- `_pane_pid` / `_tty_foreground_pgid` return `number | nil` — handled in both `shell_is_foreground` (nil-guards) and `_terminate_foreground` TERM branch.
- `M.last_paneity_command` is a string-or-nil scalar throughout.

No drift detected.

### Risks worth flagging
- The Task 2 unit tests stub `io.popen` globally. Each test restores it in the same block. Plenary-busted runs tests sequentially in one Neovim process, so cross-test pollution is theoretically possible if a test errors before restoring. Mitigated by `pcall`-style restore in `after_each` — left out for brevity, acceptable for in-repo tests.
- The "type anyway" branch in `M.run` types into a process that may be reading stdin (e.g. a wedged `read` loop). This is documented behavior of that choice — the user is explicitly opting in.
