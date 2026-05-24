# Popup-Shell Command Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `M.new_command`'s `vim.ui.input` widget with a tmux popup running a real bash shell, fronted by a single-method shell strategy interface so other shells can be added later without core changes.

**Architecture:** A new `lua/paneity/shells/<name>.lua` module per shell exposes one method, `get_command(prefill, cb)`. The bash adapter launches a detached single-pane helper session (`paneity-popup-<token>`) running `bash --rcfile <generated rcfile>`, then opens a `display-popup -E` that attaches to it. The rcfile sources the user's `~/.bashrc` for aliases/completions, then layers paneity overrides on top: `HISTFILE` switched to a global paneity file, Enter (`C-m`) rebound to a `bind -x` handler that writes `$READLINE_LINE` to a capture file and `exit 0`s. Prefill is delivered after launch by polling for a "ready" file written from `PROMPT_COMMAND`, then sending `C-x C-p` to the helper session — a `bind -x` there sets `READLINE_LINE` from an env var. Core calls `M.run(captured)` on success, runs nothing on cancel.

**Tech Stack:** Lua, Neovim API, tmux ≥ 3.2 (`display-popup -E`), bash ≥ 4.0 (`bind -x`, `$READLINE_LINE`, `PROMPT_COMMAND`), plenary.busted (existing test runner).

**Spec:** `docs/superpowers/specs/2026-05-24-popup-shell-input-design.md`

---

## File Map

**Create:**
- `lua/paneity/shells/init.lua` — registry: `{ bash = require("paneity.shells.bash") }`
- `lua/paneity/shells/bash.lua` — bash adapter; embedded rcfile string; popup orchestration
- `tests/integration/support/popup_home/.bashrc` — controlled bash env fixture for tests
- `tests/integration/popup_command_spec.lua` — integration tests for the popup feature

**Modify:**
- `lua/paneity/init.lua` — `M.new_command` body, `M.defaults` (add `shell`), drop `opts.prompt`
- `tests/integration/core_workflow_spec.lua` — rewrite the `set_and_run` helper so the existing core workflow test drives the popup-session instead of `vim.ui.input`
- `tests/integration/support/tmux_session.lua` — add helpers for finding/driving the popup-session (`wait_for_popup_session`, `popup_session_name`, `send_keys_to_popup`)
- `README.md` — document new behaviour, `shell` config, removal of `opts.prompt`, tmux 3.2+ requirement

---

## Task 1: Shell registry + bash adapter stub + `shell` default

This task introduces the strategy boundary without changing behaviour. `M.new_command` is **not** wired up yet — it still uses `vim.ui.input`. The adapter exposes `get_command` but calls `cb(nil)` immediately. We can require the module without errors.

**Files:**
- Create: `lua/paneity/shells/init.lua`
- Create: `lua/paneity/shells/bash.lua`
- Modify: `lua/paneity/init.lua` (defaults table only)

- [ ] **Step 1: Create the registry**

`lua/paneity/shells/init.lua`:

```lua
-- lua/paneity/shells/init.lua
--
-- Registry of shell adapters. Each adapter exposes a single async
-- method, get_command(prefill, cb), which presents a shell-like input
-- experience and calls cb with either the captured command string or
-- nil if the user cancelled.

return {
  bash = require("paneity.shells.bash"),
}
```

- [ ] **Step 2: Create the bash adapter stub**

`lua/paneity/shells/bash.lua`:

```lua
-- lua/paneity/shells/bash.lua
--
-- Bash adapter for the shell strategy. Launches a detached tmux
-- helper session running `bash --rcfile <generated>` and overlays it
-- with `tmux display-popup -E`. Enter inside the popup writes the
-- current readline buffer to a capture file and exits bash; the
-- adapter reads the file and invokes cb.
--
-- This stub returns cb(nil) immediately; real launch logic is added
-- in subsequent tasks.

local M = {}

-- Public test handle: name of the active helper session while a popup
-- is open, nil otherwise. Integration tests target this for send-keys.
M._active_session = nil

function M.get_command(prefill, cb)
  cb(nil)
end

return M
```

- [ ] **Step 3: Add `shell` to defaults**

In `lua/paneity/init.lua`, locate `M.defaults` (around line 472) and add `shell = "bash"` alongside the other top-level keys (above `termination`):

```lua
M.defaults = {
  log_level = vim.log.levels.OFF,
  marker = "🥖🕹️",
  split_direction = nil,
  split_size = nil,
  split_percentage_size = nil,
  shell = "bash",
  termination = {
    key_sequence    = { "C-c", "C-\\" },
    send_term       = true,
    step_timeout_ms = 200,
  },
  keybindings = {
    -- ...existing...
  },
}
```

- [ ] **Step 4: Verify the module loads**

Run from the repo root:

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua print(type(require('paneity.shells').bash.get_command))" -c "qa!"
```

Expected output: `function`

- [ ] **Step 5: Run existing tests**

```bash
make test
```

Expected: all existing tests still pass. The strategy boundary exists but isn't wired up.

- [ ] **Step 6: Commit**

```bash
git add lua/paneity/shells/init.lua lua/paneity/shells/bash.lua lua/paneity/init.lua
git commit -m "Add shell strategy boundary and bash adapter stub"
```

---

## Task 2: Test fixture — controlled bash environment

Create the fixture that integration tests will point `HOME` at, so the popup's bash sources a known `.bashrc`.

**Files:**
- Create: `tests/integration/support/popup_home/.bashrc`

- [ ] **Step 1: Write the fixture .bashrc**

`tests/integration/support/popup_home/.bashrc`:

```bash
# Fixture .bashrc used by paneity integration tests.
# When a test points $HOME at tests/integration/support/popup_home,
# the popup-shell launches a bash that sources this file. Assertions
# can then check for these markers to confirm user init was sourced.

export PANEITY_TEST_MARKER=1
alias ptest='echo PTEST'

# A known, plain PS1 so capture-pane assertions can grep for the prompt
# without dealing with the developer's local PS1 styling.
PS1='paneity_test> '
```

- [ ] **Step 2: Verify it's a valid shell script**

```bash
bash -n tests/integration/support/popup_home/.bashrc && echo OK
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add tests/integration/support/popup_home/.bashrc
git commit -m "Add controlled bash fixture for popup integration tests"
```

---

## Task 3: Tmux session helpers for popup-session

Extend the existing tmux test helper with three small functions: detect the popup-session, get its name, send keys to it. These compose existing patterns; no new tmux primitives.

**Files:**
- Modify: `tests/integration/support/tmux_session.lua`

- [ ] **Step 1: Add `popup_session_name` and friends**

In `tests/integration/support/tmux_session.lua`, inside the inner `function M.start(opts)` (around line ~70, alongside `pane_ids`, `pane_count`, `send_keys_to`), add these three methods. Place them just before the existing `function session:wait_for_pane_count(...)` definition for cohesion:

```lua
  -- Return the name of the active paneity popup helper session, or
  -- nil if none exists in this sandbox's tmux server. The adapter
  -- names sessions `paneity-popup-<16-hex>`.
  function session:popup_session_name()
    local out = tmux_cmd("list-sessions -F '#{session_name}' 2>/dev/null")
    return out:match("(paneity%-popup%-%x+)")
  end

  function session:wait_for_popup_session(timeout_ms)
    return vim.wait(timeout_ms or 3000, function()
      return self:popup_session_name() ~= nil
    end, 50)
  end

  function session:wait_for_no_popup_session(timeout_ms)
    return vim.wait(timeout_ms or 3000, function()
      return self:popup_session_name() == nil
    end, 50)
  end

  -- Capture-pane on the popup helper session's only pane.
  function session:popup_pane_text()
    local name = self:popup_session_name()
    if not name then return "" end
    return tmux_cmd(string.format(
      "capture-pane -t %s:0.0 -p", name))
  end

  function session:send_keys_to_popup(payload)
    local name = self:popup_session_name()
    assert(name, "send_keys_to_popup: no popup session is active")
    tmux_cmd(string.format(
      "send-keys -t %s:0.0 %s", name, payload))
  end

  function session:wait_for_popup_prompt(timeout_ms)
    return vim.wait(timeout_ms or 5000, function()
      return self:popup_pane_text():find("paneity_test>", 1, true) ~= nil
    end, 50)
  end
```

- [ ] **Step 2: Smoke-test the helpers compile**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua local s = require('tests.integration.support.tmux_session'); assert(type(s.start) == 'function')" \
  -c "qa!"
```

Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add tests/integration/support/tmux_session.lua
git commit -m "Add popup-session helpers to tmux integration support"
```

---

## Task 4: Headline integration test (red)

Write the integration test that defines the feature. It triggers the popup, drives it via the popup-session, asserts the captured command lands in the target pane. Will fail because `M.new_command` still uses `vim.ui.input`.

**Files:**
- Create: `tests/integration/popup_command_spec.lua`

- [ ] **Step 1: Write the spec scaffold and the headline test**

`tests/integration/popup_command_spec.lua`:

```lua
-- tests/integration/popup_command_spec.lua
--
-- Integration tests for the popup-shell command input feature.
-- Tests drive a real bash popup inside the tmux sandbox via
-- send-keys to the helper session (paneity-popup-<token>).

local tmux_session = require("tests.integration.support.tmux_session")
local fs           = require("tests.integration.support.fs")
local wait         = require("tests.integration.support.wait")

local REPO_ROOT = vim.fn.fnamemodify(
  vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h")

local POPUP_HOME = REPO_ROOT .. "/tests/integration/support/popup_home"

describe("popup-shell command input", function()
  local session
  local log_file
  local sample_file

  before_each(function()
    session = tmux_session.start({ name = "paneity_popup" })
    log_file    = session:path("cmd.log")
    sample_file = session:path("sample.txt")
    vim.fn.writefile({ "sample contents" }, sample_file)

    -- Inner nvim runs with HOME pointed at the fixture so the popup's
    -- bash sources our known .bashrc (PS1, PANEITY_TEST_MARKER, ptest).
    session:start_nvim({
      file = sample_file,
      init_lines = {
        "vim.env.HOME = " .. string.format("%q", POPUP_HOME),
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
    session:send_keys("Space t p")
    assert.is_true(session:wait_for_pane_count(2),
      "expected paneity to create a second pane within 3s")
    for _, id in ipairs(session:pane_ids()) do
      if id ~= session.nvim_pane_id then return id end
    end
    error("could not find paneity target pane id")
  end

  it("captures a command typed in the popup and runs it in the target", function()
    activate_paneity()

    -- <leader>tc -> M.new_command -> popup. With sample.txt as the
    -- active buffer, the default prefill is the buffer's file path
    -- relative to nvim's cwd.
    session:send_keys("Space t c")
    assert.is_true(session:wait_for_popup_session(),
      "expected popup session within 3s")
    assert.is_true(session:wait_for_popup_prompt(),
      "expected popup bash prompt within 5s")

    -- Default prefill should be visible in the popup pane. This proves
    -- the prefill mechanism wired up; the rest of the test exercises
    -- capture + transmission with a clean, controllable command.
    local popup_text = session:popup_pane_text()
    assert.is_truthy(popup_text:find("sample.txt", 1, true),
      "expected default prefill (sample.txt) at popup prompt; got: " .. popup_text)

    -- Clear the prefill (C-a -> BOL, C-k -> kill to EOL), then type a
    -- known command that writes a token to the log file. The target
    -- pane's bash will execute it.
    local token = fs.random_token()
    session:send_keys_to_popup("C-a C-k")
    session:send_keys_to_popup(string.format(
      "%s Enter",
      vim.fn.shellescape("echo " .. token .. " >> " .. log_file)))

    -- Popup closes when bash exits via __paneity_capture.
    assert.is_true(session:wait_for_no_popup_session(),
      "expected popup session to disappear within 3s")

    -- Target pane should have run the echo and written the token.
    assert.is_true(wait.until_true(function()
      return #fs.read_lines(log_file) >= 1
    end, 5000), "expected target pane to write log line within 5s")

    assert.are.equal(token, fs.read_lines(log_file)[1])
  end)
end)
```

> **Note for the executor:** Yes, the test's "command typed into the popup" includes the literal file path as a prefix, which target bash will try to execute. The test deliberately asserts only that (a) the token reached the log file and (b) the file path appears in the target pane's scrollback. Both pieces prove the popup capture + transmission worked. A cleaner future test could use `opts.prefill = ""` to control exactly what gets sent; we add that test in Task 12.

- [ ] **Step 2: Run the test — expect failure**

```bash
make test
```

Expected: this new spec fails. The failure mode should be a timeout on `wait_for_popup_session` (the popup never appears because `M.new_command` still uses `vim.ui.input`). The existing `core_workflow_spec.lua` will still pass.

- [ ] **Step 3: Commit**

```bash
git add tests/integration/popup_command_spec.lua
git commit -m "Add failing headline integration test for popup-shell input"
```

---

## Task 5: Bash adapter — rcfile, temp files, session, popup launch (no prefill yet)

Implement the meat of the bash adapter. After this task the headline test still fails (no prefill delivery), but if you manually drive the popup with a typed command, Enter, the captured command makes it back to `cb`.

**Files:**
- Modify: `lua/paneity/shells/bash.lua`

- [ ] **Step 1: Replace the stub with the full launch flow (prefill deferred)**

Overwrite `lua/paneity/shells/bash.lua` with:

```lua
-- lua/paneity/shells/bash.lua
--
-- Bash adapter for the shell strategy. Launches a detached tmux
-- helper session running `bash --rcfile <generated>` and overlays it
-- with `tmux display-popup -E`. Enter inside the popup writes the
-- current readline buffer to a capture file and exits bash; the
-- adapter reads the file and invokes cb.

local uv = vim.uv or vim.loop

local M = {}

-- Public test handle: name of the active helper session while a popup
-- is open, nil otherwise. Integration tests target this for send-keys.
M._active_session = nil

-- Embedded rcfile contents. Sourcing order matters: user init first
-- (aliases, completions, PS1), then paneity overrides so anything the
-- user binds to Enter or sets as HISTFILE gets stomped. `bind -x` runs
-- the function in the current shell, so `exit 0` from __paneity_capture
-- terminates bash before any command parsing happens.
local RCFILE = [=[
[ -r /etc/profile ]    && . /etc/profile
[ -r ~/.bash_profile ] && . ~/.bash_profile
[ -r ~/.bashrc ]       && . ~/.bashrc

cd "$PANEITY_CWD" 2>/dev/null || true

export HISTFILE="$PANEITY_HISTFILE"
export HISTSIZE=1000
export HISTFILESIZE=1000
history -c
history -r

__paneity_capture() {
  printf '%s\n' "$READLINE_LINE" > "$PANEITY_CAPTURE"
  if [ -n "$READLINE_LINE" ]; then
    history -s -- "$READLINE_LINE"
    history -a
  fi
  exit 0
}
bind -x '"\C-m": __paneity_capture'
bind -x '"\C-j": __paneity_capture'

trap 'exit 130' INT

__paneity_prefill_now() {
  READLINE_LINE="$PANEITY_PREFILL"
  READLINE_POINT=${#PANEITY_PREFILL}
}
bind -x '"\C-x\C-p": __paneity_prefill_now'

__paneity_signal_ready() {
  if [ -z "$_paneity_ready_sent" ]; then
    : > "$PANEITY_READY"
    _paneity_ready_sent=1
  fi
}
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }__paneity_signal_ready"
]=]

local function random_token()
  math.randomseed(os.time() + math.floor(os.clock() * 1e6))
  return string.format("%08x%08x",
    math.random(0, 2 ^ 31 - 1), math.random(0, 2 ^ 31 - 1))
end

local function temp_path(suffix)
  return string.format("/tmp/paneity-%s-%s", suffix, random_token())
end

local function write_file(path, contents)
  local f, err = io.open(path, "w")
  if not f then error("paneity: cannot write " .. path .. ": " .. (err or "?")) end
  f:write(contents)
  f:close()
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function unlink(path)
  if path then pcall(os.remove, path) end
end

local function default_histfile()
  local data = vim.env.XDG_DATA_HOME or (vim.env.HOME .. "/.local/share")
  return data .. "/paneity/history"
end

local function tmux(args)
  local out = vim.fn.system("tmux " .. args)
  return out, vim.v.shell_error
end

local function shesc(s)
  return vim.fn.shellescape(s or "")
end

function M.get_command(prefill, cb)
  local session_name = "paneity-popup-" .. random_token()
  local rcfile_path  = temp_path("rcfile")
  local capture_path = temp_path("capture")
  local ready_path   = temp_path("ready")
  local histfile     = default_histfile()
  local cwd          = vim.fn.getcwd()

  -- HISTFILE parent must exist before bash tries to read/write it.
  vim.fn.mkdir(vim.fn.fnamemodify(histfile, ":h"), "p")
  write_file(rcfile_path, RCFILE)

  local env_flags = table.concat({
    "-e PANEITY_PREFILL="  .. shesc(prefill or ""),
    "-e PANEITY_CAPTURE="  .. shesc(capture_path),
    "-e PANEITY_HISTFILE=" .. shesc(histfile),
    "-e PANEITY_READY="    .. shesc(ready_path),
    "-e PANEITY_CWD="      .. shesc(cwd),
  }, " ")

  -- Detached single-pane session running bash. The session is the
  -- popup's addressable handle; when bash exits the session dies.
  local _, code = tmux(string.format(
    "new-session -d -s %s -x 200 -y 50 %s bash --rcfile %s",
    shesc(session_name), env_flags, shesc(rcfile_path)))

  if code ~= 0 then
    unlink(rcfile_path)
    cb(nil)
    return
  end

  M._active_session = session_name

  local cleaned_up = false
  local function cleanup_and_callback(captured)
    if cleaned_up then return end
    cleaned_up = true
    M._active_session = nil
    -- Kill the session if it still exists (e.g. error path before bash
    -- exited normally). Errors here are deliberately ignored.
    tmux("kill-session -t " .. shesc(session_name) .. " 2>/dev/null")
    unlink(rcfile_path)
    unlink(capture_path)
    unlink(ready_path)
    cb(captured)
  end

  local function on_popup_exit()
    local raw = read_file(capture_path)
    if not raw or raw == "" or raw == "\n" then
      cleanup_and_callback(nil)
      return
    end
    local trimmed = raw:gsub("\n$", "")
    if trimmed == "" then
      cleanup_and_callback(nil)
    else
      cleanup_and_callback(trimmed)
    end
  end

  -- Run `display-popup -E` async. TMUX is unset so the inner
  -- `tmux attach-session` doesn't refuse on nesting; tmux finds the
  -- right socket via $TMUX_TMPDIR / default discovery.
  local popup_cmd = string.format(
    "TMUX= tmux display-popup -E 'tmux attach-session -t %s'",
    shesc(session_name))

  vim.fn.jobstart({ "sh", "-c", popup_cmd }, {
    on_exit = function() vim.schedule(on_popup_exit) end,
  })
end

return M
```

- [ ] **Step 2: Smoke-launch the popup manually (sanity check)**

This is a quick interactive sanity check before wiring it into the integration test. Open a tmux pane, then:

```bash
nvim --noplugin -u tests/minimal_init.lua
```

Inside the inner nvim:

```vim
:lua require('paneity.shells.bash').get_command('', function(c) print('got: ' .. vim.inspect(c)) end)
```

Expected: a popup appears, you can type `echo hi`, press Enter, popup closes, nvim prints `got: "echo hi"`.

If the popup never appears or the inner `tmux attach-session` errors with "sessions should be nested with care, unset $TMUX", verify that `TMUX=` is being honoured. On some tmux versions the inner attach also needs `-d` (detach others). Adjust the `popup_cmd` template if necessary; the rest of the adapter is unaffected.

- [ ] **Step 3: Re-run integration tests**

```bash
make test
```

Expected: `core_workflow_spec.lua` still passes (M.new_command unchanged). `popup_command_spec.lua` still fails — but now the failure is later, because the popup *does* open; the spec fails on the missing prefill (the file path isn't in the popup pane text). That is the next task.

- [ ] **Step 4: Commit**

```bash
git add lua/paneity/shells/bash.lua
git commit -m "Implement bash popup adapter (capture and exit on Enter)"
```

---

## Task 6: Bash adapter — prefill delivery

Wire the ready-file polling + `tmux send-keys` trigger so the configured prefill appears in the popup's readline buffer before the user types.

**Files:**
- Modify: `lua/paneity/shells/bash.lua`

- [ ] **Step 1: Add the prefill polling timer**

In `lua/paneity/shells/bash.lua`, locate the section near the end of `M.get_command` that starts with `-- Run \`display-popup -E\` async.` Insert the prefill polling block **before** the `vim.fn.jobstart(...)` call. The full bottom of `get_command` should look like:

```lua
  -- Prefill: poll for the ready marker, then send the trigger key to
  -- the helper session. PROMPT_COMMAND writes the ready file before
  -- readline starts, so the keystroke lands inside the bind -x handler
  -- which populates READLINE_LINE from $PANEITY_PREFILL.
  if prefill and prefill ~= "" then
    local timer = uv.new_timer()
    timer:start(25, 25, vim.schedule_wrap(function()
      if vim.fn.filereadable(ready_path) == 1 then
        timer:stop()
        timer:close()
        tmux(string.format(
          "send-keys -t %s:0.0 C-x C-p", shesc(session_name)))
      end
    end))
    -- Safety: stop the timer if the popup exits before ready fires.
    -- We piggyback on cleanup_and_callback via a wrapper below.
    local original_cleanup = cleanup_and_callback
    cleanup_and_callback = function(captured)
      if not timer:is_closing() then
        pcall(function() timer:stop(); timer:close() end)
      end
      original_cleanup(captured)
    end
  end

  -- Run `display-popup -E` async. TMUX is unset so the inner
  -- `tmux attach-session` doesn't refuse on nesting; tmux finds the
  -- right socket via $TMUX_TMPDIR / default discovery.
  local popup_cmd = string.format(
    "TMUX= tmux display-popup -E 'tmux attach-session -t %s'",
    shesc(session_name))

  vim.fn.jobstart({ "sh", "-c", popup_cmd }, {
    on_exit = function() vim.schedule(on_popup_exit) end,
  })
end
```

Note: declaring `local cleanup_and_callback` earlier and then re-assigning it as `cleanup_and_callback = function ...` would shadow it. To keep this simple, change the original declaration of `cleanup_and_callback` from `local function cleanup_and_callback(captured)` to:

```lua
  local cleanup_and_callback
  cleanup_and_callback = function(captured)
    -- ... existing body ...
  end
```

so the later re-assignment in the prefill branch wraps the original.

- [ ] **Step 2: Re-run the headline integration test**

```bash
make test
```

Expected: `popup_command_spec.lua` headline test now **passes**. The popup opens, prefill (`sample.txt`) is visible, test types its appended payload, Enter captures, target pane receives, log is written. `core_workflow_spec.lua` still passes (M.new_command unchanged so the existing test path is unaffected).

If the prefill assertion still fails:
- Verify the ready file is being written: add a temporary `vim.notify(vim.inspect(vim.fn.filereadable(ready_path)))` inside the timer callback.
- Verify `tmux send-keys -t <name>:0.0 C-x C-p` reaches the helper session: open the test sandbox manually and reproduce.

- [ ] **Step 3: Commit**

```bash
git add lua/paneity/shells/bash.lua
git commit -m "Add prefill delivery via ready-poll and send-keys"
```

---

## Task 7: Wire `M.new_command`, default prefill, drop `opts.prompt`

Flip the core to use the adapter. This is the breaking change.

**Files:**
- Modify: `lua/paneity/init.lua`

- [ ] **Step 1: Replace the `M.new_command` body**

In `lua/paneity/init.lua`, replace the existing `M.new_command` (lines ~435-455, the version that calls `vim.ui.input`) with:

```lua
local function default_prefill()
  if vim.bo.buftype ~= "" then return "" end
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then return "" end
  return vim.fn.fnamemodify(name, ":.")
end

function M.new_command(opts)
  opts = vim.tbl_deep_extend("force", { post_exec = false }, opts or {})

  if not M.target_pane_id then
    print_error("no target pane set.")
    return
  end

  -- nil = compute default; "" = explicit no-prefill.
  local prefill = opts.prefill
  if prefill == nil then prefill = default_prefill() end

  require("paneity.shells")[M.config.shell].get_command(prefill, function(command)
    if command and command ~= "" then
      print_message("Running command: " .. command)
      M.run(command)
      if opts.post_exec then opts.post_exec(command) end
    end
  end)
end
```

Note: `default_prefill` is a file-local helper. Put it just above the `function M.new_command(opts)` definition.

- [ ] **Step 2: Confirm no other `opts.prompt` references remain**

```bash
grep -n "opts.prompt\|prompt =" lua/paneity/init.lua
```

Expected: no matches for `opts.prompt`. (Other uses of `prompt =` elsewhere — e.g. `vim.ui.input` calls for unrelated features — should not exist; the codebase only uses it here.)

- [ ] **Step 3: Verify shells module is wired**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua require('paneity').setup({})" \
  -c "lua assert(require('paneity').config.shell == 'bash')" \
  -c "qa!"
```

Expected: exit 0 with no errors.

- [ ] **Step 4: Run tests**

```bash
make test
```

Expected: `popup_command_spec.lua` still passes. `core_workflow_spec.lua` now **fails** because its `set_and_run` helper still types into the (gone) `vim.ui.input`. Task 8 fixes this.

- [ ] **Step 5: Commit**

```bash
git add lua/paneity/init.lua
git commit -m "Route M.new_command through shell strategy adapter"
```

---

## Task 8: Update core_workflow_spec to drive the popup

The existing core workflow test's `set_and_run` helper assumes `vim.ui.input`. Rewrite it to drive the popup-session.

**Files:**
- Modify: `tests/integration/core_workflow_spec.lua`

- [ ] **Step 1: Rewrite `set_and_run`**

In `tests/integration/core_workflow_spec.lua`, locate the `set_and_run` local function (around line ~55). Replace it with:

```lua
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
```

- [ ] **Step 2: The core workflow test inherits `HOME` requirement**

The new `set_and_run` uses `wait_for_popup_prompt`, which greps for `paneity_test>` (the fixture PS1). That only works if `HOME` points at the fixture. Add `HOME` to the test's inner init.

Locate the `before_each` block (around line ~25) where `session:start_nvim()` is called with no args. Replace that call with:

```lua
    local REPO_ROOT = vim.fn.fnamemodify(
      vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h")
    local POPUP_HOME = REPO_ROOT .. "/tests/integration/support/popup_home"
    session:start_nvim({
      init_lines = {
        "vim.env.HOME = " .. string.format("%q", POPUP_HOME),
        string.format("vim.opt.runtimepath:prepend(%q)", REPO_ROOT),
        "vim.g.mapleader = ' '",
        "require('paneity').setup({})",
      },
    })
```

- [ ] **Step 3: Run tests**

```bash
make test
```

Expected: both `core_workflow_spec.lua` and `popup_command_spec.lua` pass.

- [ ] **Step 4: Commit**

```bash
git add tests/integration/core_workflow_spec.lua
git commit -m "Drive popup-session from core workflow spec"
```

---

## Task 9: Integration test — cancel via Ctrl-C

Add a test asserting that Ctrl-C in the popup is a no-op for the target.

**Files:**
- Modify: `tests/integration/popup_command_spec.lua`

- [ ] **Step 1: Add the cancel test**

Append the following `it(...)` block inside the existing `describe("popup-shell command input", ...)`:

```lua
  it("does not touch the target pane when the popup is cancelled with C-c", function()
    activate_paneity()

    session:send_keys("Space t c")
    assert.is_true(session:wait_for_popup_session(),
      "expected popup session within 3s")
    assert.is_true(session:wait_for_popup_prompt(),
      "expected popup bash prompt within 5s")

    -- Ctrl-C triggers `trap 'exit 130' INT` in the rcfile. Bash exits
    -- without writing the capture file → adapter calls cb(nil).
    session:send_keys_to_popup("C-c")

    assert.is_true(session:wait_for_no_popup_session(),
      "expected popup session to close after C-c within 3s")

    -- No log file should have been created; previous_command unchanged
    -- (still nil since we never ran anything). The simplest assertion:
    -- the log file is absent.
    assert.is_false(fs.exists(log_file),
      "expected no command to have been sent to the target")
  end)
```

- [ ] **Step 2: Run tests**

```bash
make test
```

Expected: all integration tests pass.

- [ ] **Step 3: Commit**

```bash
git add tests/integration/popup_command_spec.lua
git commit -m "Assert popup C-c cancel is a no-op for the target"
```

---

## Task 10: Integration test — user init really sourced

Verify that the popup bash sees the fixture's `PANEITY_TEST_MARKER` env var, proving `~/.bashrc` was sourced inside the popup.

**Files:**
- Modify: `tests/integration/popup_command_spec.lua`

- [ ] **Step 1: Add the user-init-sourced test**

Append inside the `describe(...)`:

```lua
  it("sources the user's bashrc inside the popup", function()
    activate_paneity()

    session:send_keys("Space t c")
    assert.is_true(session:wait_for_popup_session(),
      "expected popup session within 3s")
    assert.is_true(session:wait_for_popup_prompt(),
      "expected popup bash prompt within 5s")

    -- The fixture .bashrc sets PS1='paneity_test> '. If we see that
    -- string in the popup pane, bash inside the popup sourced our
    -- ~/.bashrc — which is what "user init was loaded" means in
    -- practice. wait_for_popup_prompt already polls for this; the
    -- explicit assertion documents the intent of the test.
    local popup_text = session:popup_pane_text()
    assert.is_truthy(popup_text:find("paneity_test>", 1, true),
      "expected fixture PS1 in popup, proving .bashrc was sourced; got: "
      .. popup_text)

    -- Cancel so after_each can tear down cleanly.
    session:send_keys_to_popup("C-c")
    assert.is_true(session:wait_for_no_popup_session())
  end)
```

- [ ] **Step 2: Run tests**

```bash
make test
```

Expected: all integration tests pass.

- [ ] **Step 3: Commit**

```bash
git add tests/integration/popup_command_spec.lua
git commit -m "Assert popup sources user bashrc (fixture PS1 visible)"
```

---

## Task 11: Integration test — `opts.prefill = ""` overrides default

Verify that an explicit empty prefill suppresses the default file-path prefill.

**Files:**
- Modify: `tests/integration/popup_command_spec.lua`

- [ ] **Step 1: Add the explicit-empty-prefill test**

Append inside the `describe(...)`:

```lua
  it("uses opts.prefill = '' to suppress the default file-path prefill", function()
    activate_paneity()

    -- Invoke M.new_command directly via :lua so we can pass opts. We
    -- need to wait for the popup session as usual, then assert the
    -- prompt line has nothing after the prompt suffix.
    session:send_keys(
      vim.fn.shellescape(":lua require('paneity').new_command({ prefill = '' })")
      .. " Enter")

    assert.is_true(session:wait_for_popup_session(),
      "expected popup session within 3s")
    assert.is_true(session:wait_for_popup_prompt(),
      "expected popup bash prompt within 5s")

    -- Give the prefill polling timer a few ticks to NOT fire (it
    -- shouldn't, because prefill is empty). Then capture the pane and
    -- assert the trailing line is just the prompt with no content.
    vim.wait(200)

    local lines = {}
    for line in (session:popup_pane_text() .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, line)
    end
    -- Find the last non-blank line; it should end with the prompt
    -- suffix and have nothing after it.
    local last
    for i = #lines, 1, -1 do
      if lines[i] ~= "" then last = lines[i]; break end
    end
    assert.is_truthy(last and last:match("paneity_test> *$"),
      "expected empty input after prompt; got last line: " .. tostring(last))

    -- Clean up: cancel the popup so after_each can destroy the session.
    session:send_keys_to_popup("C-c")
    assert.is_true(session:wait_for_no_popup_session())
  end)
```

- [ ] **Step 2: Run tests**

```bash
make test
```

Expected: all integration tests pass.

- [ ] **Step 3: Commit**

```bash
git add tests/integration/popup_command_spec.lua
git commit -m "Assert opts.prefill = '' overrides default file prefill"
```

---

## Task 12: README update

Document the new behaviour, the `shell` config, the removal of `opts.prompt`, and the tmux 3.2+ requirement.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the current README**

```bash
cat README.md | head -200
```

Identify the section that documents `M.new_command` / `<leader>tc` / `prompt`. There is at least one mention of the old `prompt` opt; replace it with the new shape.

- [ ] **Step 2: Update the documented opts for new_command**

Find any block that describes `M.new_command`'s opts (likely something like a config example or a "scripting" subsection). Replace the documented opts table with:

```markdown
`M.new_command(opts)` accepts:

- `prefill` (`string | nil`) — initial content of the popup's command
  line. `nil` (the default) uses the active buffer's file path relative
  to nvim's cwd, or an empty string for non-file buffers. Pass `""` to
  explicitly suppress the default.
- `post_exec` (`function | nil`) — called with the captured command
  string after `M.run` returns.

`opts.prompt` was removed in this release; the popup shows the user's
own bash prompt (`PS1`) instead of a configurable label.
```

- [ ] **Step 3: Add a "Requirements" note about tmux**

Locate the requirements / installation section. If the file already says "requires tmux", append:

```markdown
- tmux **3.2 or newer** is required (uses `display-popup -E` for the new-command popup).
```

If no such section exists, add one near the top.

- [ ] **Step 4: Document the `shell` config**

In the "Configuration" or "Setup" section, add the new config key:

```markdown
- `shell` (string, default `"bash"`) — which shell adapter to use for
  the new-command popup. Only `"bash"` is implemented in this release;
  the strategy interface is designed so that other shells (`"zsh"`,
  `"fish"`) can be added without core changes.
```

- [ ] **Step 5: Smoke-render the README locally if you have a markdown viewer; otherwise read it back**

```bash
sed -n '1,200p' README.md
```

Spot-check that the changes flow naturally.

- [ ] **Step 6: Run tests one more time to confirm nothing regressed**

```bash
make test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add README.md
git commit -m "Document popup-shell input, shell config, and tmux 3.2 requirement"
```

---

## Done

After Task 12:

- New command input goes through a real bash popup with full aliases/completions.
- Shell strategy interface is in place; adding `zsh` or `fish` is a new file under `lua/paneity/shells/`.
- Integration tests cover: default prefill happy path, cancel via Ctrl-C, user init sourced (fixture PS1), explicit empty prefill.
- Existing core workflow test continues to pass via the popup-session.
- README reflects the new behaviour and the breaking change.

## Verification checklist (run before opening a PR)

- [ ] `make test` is fully green.
- [ ] Manually trigger `<leader>tc` in a real nvim + tmux session and confirm:
  - The popup opens with the current file path prefilled.
  - Tab completion completes file names from the current directory.
  - A user-defined alias (e.g. `gs` for `git status`) is visible via `alias` inside the popup.
  - Pressing Enter sends the (alias-expanded by the target's shell, since the popup never executes) command to the target pane.
  - Pressing Ctrl-C in the popup does nothing to the target.
- [ ] Confirm `~/.local/share/paneity/history` (or `$XDG_DATA_HOME/paneity/history`) gets entries appended.
- [ ] Confirm tmux server has no leftover `paneity-popup-*` sessions after the popup closes (`tmux list-sessions`).
