# Core-Workflow Integration Test — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single integration test that drives the full user workflow (open file → activate paneity → set & run a command → repeat) against a real nvim running inside a real tmux pane, with no internal seams stubbed.

**Architecture:** New plenary-busted spec at `tests/integration/core_workflow_spec.lua`. Per-test setup creates an isolated tmux server (`TMUX_TMPDIR`), spawns one pane running `nvim --clean -u <inner_init> <file>`, where `<inner_init>` is written to the tmpdir and prepends repo root to runtimepath, sets `vim.g.mapleader = " "`, calls `paneity.setup({})`, and writes a ready-marker file. Test drives the inner nvim entirely via `tmux send-keys`. Verification is by polling a log file the user-command writes to, asserting each line equals a per-run random token.

**Tech Stack:** Lua 5.1 (Neovim Lua), Plenary busted (`describe` / `it` / `before_each` / `after_each`), tmux CLI invoked via `vim.fn.system`, native Neovim APIs (`vim.wait`, `vim.fn.writefile`, `vim.env`, `io.open`).

---

## File Structure

- **Create:** `tests/integration/core_workflow_spec.lua` — the only new file. All helpers and the single test case live here.

No other files are modified. The existing `tests/minimal_init.lua` already prepends the repo root for the test-runner nvim; the inner nvim gets its own init written into the tmpdir per-test.

---

## Conventions

- Imports/requires inside `it` blocks are not needed — the test never `require("paneity")` from the test-runner nvim.
- `vim.fn.system` is used for shell calls (existing pattern). `vim.fn.shellescape` for argument quoting.
- `assert.*` is the plenary/busted assertion API (`assert.is_true`, `assert.are.same`).
- All tmux invocations go through the local `tmux(args)` helper (matches the existing integration spec's style).
- All polls go through `wait_until(predicate, timeout_ms, interval_ms)` (matches the existing spec).

---

## Task 1: Scaffold the test file

Create the file with helpers, lifecycle hooks (tmpdir + isolated tmux server only — no inner nvim yet), and an empty `it` block. The goal is to confirm the file is picked up by `make test` and that the lifecycle hooks run cleanly.

**Files:**
- Create: `tests/integration/core_workflow_spec.lua`

- [ ] **Step 1.1: Create the file**

```lua
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
```

- [ ] **Step 1.2: Run the test to confirm it's picked up**

Run: `make test`

Expected: the new spec is discovered. The single `it` block passes (empty body → no assertions → pass). The existing specs continue to pass. Look for `Success || core workflow activates paneity, runs a command, and repeats it` in the output.

- [ ] **Step 1.3: Commit**

```bash
git add tests/integration/core_workflow_spec.lua
git commit -m "Add scaffolding for core-workflow integration test"
```

---

## Task 2: Launch real nvim inside the tmux pane

Extend `before_each` to write an inner init file, write a "file to edit", spawn a tmux session running `nvim --clean -u <inner_init> <file>`, and wait for the inner nvim to write a ready-marker file. Add an assertion inside the `it` block that the marker exists — this proves the inner nvim ran our init and reached `paneity.setup({})`.

**Files:**
- Modify: `tests/integration/core_workflow_spec.lua`

- [ ] **Step 2.1: Add repo-root resolution at the top of the file**

Insert immediately after the file header comment (before the helper functions):

```lua
local repo_root = vim.fn.fnamemodify(
  vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h"
)
```

Rationale: this file is `tests/integration/core_workflow_spec.lua`. `:p:h:h:h` walks three directories up (`integration/` → `tests/` → repo root), matching the structure `tests/minimal_init.lua` uses with `:p:h:h` from one level higher.

- [ ] **Step 2.2: Add per-test path locals inside the describe block**

Replace the `local tmux_tmpdir` line with:

```lua
  local tmux_tmpdir
  local session = "paneity_core_workflow"
  local ready_marker, log_file, inner_init, edit_file
```

- [ ] **Step 2.3: Extend `before_each` to spawn the inner nvim**

Replace the body of `before_each` with:

```lua
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
```

- [ ] **Step 2.4: Add a smoke assertion in the `it` block**

Replace the placeholder comment inside `it(...)` with:

```lua
    -- Smoke check: inner nvim is up. (before_each already asserted on the
    -- ready marker, but checking here makes the test self-explanatory.)
    assert.is_true(file_exists(ready_marker))

    -- Initial state: one pane in the session.
    assert.are.equal(1, count_panes(session))
```

- [ ] **Step 2.5: Run the test**

Run: `make test`

Expected: the test passes. If it doesn't, the most likely failure is the 5s timeout — investigate by running `nvim --clean -u <inner_init> <edit_file>` manually in a terminal and seeing if it errors. The inner init is written under `<tmpdir>/init.lua` and remains on disk until `after_each` runs (so if the test fails mid-flight, you can inspect it).

- [ ] **Step 2.6: Commit**

```bash
git add tests/integration/core_workflow_spec.lua
git commit -m "Spawn real nvim inside test tmux pane with ready signal"
```

---

## Task 3: Drive activation via `<leader>tp`

Send the toggle keybinding to the inner nvim. Paneity sees only one pane (excluding the one running nvim, which is itself) so `choose_tmux_pane` takes the single-pane auto branch and `open_new_pane` creates a sibling pane. Wait for the pane count to reach 2 and assert.

**Files:**
- Modify: `tests/integration/core_workflow_spec.lua`

- [ ] **Step 3.1: Add the activation step to the `it` block**

Append to the `it` block (immediately after the initial `count_panes` assertion):

```lua
    -- Step 1: activate paneity. <leader>tp -> M.toggle -> M.set_target_pane
    -- -> choose_tmux_pane. Only one pane exists (excluding current), so the
    -- menu has just "New pane" and the UI is bypassed: open_new_pane runs.
    tmux(string.format("send-keys -t %s Space t p", session))

    local got_new_pane = wait_until(function()
      return count_panes(session) == 2
    end, 3000)
    assert.is_true(got_new_pane,
      "expected paneity to create a second pane within 3s")
```

- [ ] **Step 3.2: Run the test**

Run: `make test`

Expected: passes. If it fails on the `got_new_pane` assertion, check:
- Is `vim.g.mapleader = " "` set before `paneity.setup({})` in the inner init? (Required for `<leader>tp` to bind to `<Space>tp`.)
- Did paneity's `print_message` write an error? Run with `:lua require('paneity').setup({log_level = vim.log.levels.DEBUG})` adjusted in the inner init and inspect `/tmp/paneity.log`.

- [ ] **Step 3.3: Commit**

```bash
git add tests/integration/core_workflow_spec.lua
git commit -m "Cover paneity activation via <leader>tp keybinding"
```

---

## Task 4: Drive "set and run a command" via `<leader>tc`

Generate a per-run random token, send `<leader>tc` to open the input prompt, then type `echo <TOKEN> >> <log_file>` followed by Enter. Wait for the log file to contain exactly one line equal to the token.

**Files:**
- Modify: `tests/integration/core_workflow_spec.lua`

- [ ] **Step 4.1: Add a token helper at the top of the file**

Insert immediately after the existing helper functions (after `count_panes`):

```lua
local function random_token()
  math.randomseed(os.time() + math.floor(os.clock() * 1e6))
  return string.format("%08x%08x",
    math.random(0, 2 ^ 31 - 1), math.random(0, 2 ^ 31 - 1))
end
```

- [ ] **Step 4.2: Add the run-command step to the `it` block**

Append to the `it` block (immediately after the activation assertions):

```lua
    -- Step 2: set and run a command. <leader>tc -> M.new_command opens
    -- vim.ui.input. Type the command, then Enter -> M.run runs it in the
    -- paneity-created pane, which appends one line containing TOKEN to
    -- log_file.
    local token = random_token()
    local user_command = string.format("echo %s >> %s", token, log_file)

    tmux(string.format("send-keys -t %s Space t c", session))
    tmux(string.format("send-keys -t %s %s Enter",
      session, vim.fn.shellescape(user_command)))

    local first_run_done = wait_until(function()
      local lines = read_lines(log_file)
      return #lines >= 1
    end, 5000)
    assert.is_true(first_run_done,
      "expected the command to write to the log within 5s")
    assert.are.same({ token }, read_lines(log_file))
```

- [ ] **Step 4.3: Run the test**

Run: `make test`

Expected: passes. If the log file ends up with extra lines (e.g., a shell startup file echoing something), the final `assert.are.same` will fail loudly with the unexpected lines visible in the diff.

- [ ] **Step 4.4: Commit**

```bash
git add tests/integration/core_workflow_spec.lua
git commit -m "Cover \"set and run a command\" via <leader>tc keybinding"
```

---

## Task 5: Drive "repeat" via `<leader><leader>`

Send the repeat keybinding and wait for the log file to grow to exactly two lines, both equal to the token.

**Files:**
- Modify: `tests/integration/core_workflow_spec.lua`

- [ ] **Step 5.1: Add the repeat step to the `it` block**

Append to the `it` block (immediately after the first-run assertions):

```lua
    -- Step 3: repeat. <leader><leader> -> M.repeat_command ->
    -- M.run(M.previous_command). The same command re-runs in the paneity
    -- pane, appending a second TOKEN line to log_file.
    tmux(string.format("send-keys -t %s Space Space", session))

    local repeat_done = wait_until(function()
      return #read_lines(log_file) >= 2
    end, 5000)
    assert.is_true(repeat_done,
      "expected repeat to add a second line within 5s")
    assert.are.same({ token, token }, read_lines(log_file))
```

- [ ] **Step 5.2: Run the test**

Run: `make test`

Expected: passes. If repeat doesn't fire, the most likely cause is that `<Space><Space>` isn't reaching the keymap (e.g., we're stuck in some prompt). After the previous step, vim.ui.input has returned and we're back in normal mode, so `<Space><Space>` should map.

- [ ] **Step 5.3: Commit**

```bash
git add tests/integration/core_workflow_spec.lua
git commit -m "Cover repeat via <leader><leader> keybinding"
```

---

## Task 6: Run the whole suite + manual sanity check

A final pass to make sure the new test plays nice alongside the existing specs, and a quick eyeball at the file.

- [ ] **Step 6.1: Run the full suite**

Run: `make test`

Expected: all specs pass — `tests/unit/terminate_foreground_spec.lua`, `tests/integration/terminate_foreground_spec.lua`, and the new `tests/integration/core_workflow_spec.lua`.

- [ ] **Step 6.2: Re-read the final test file**

Open `tests/integration/core_workflow_spec.lua` and skim for:
- Helpers are defined before `describe`.
- `repo_root` is computed once at file scope.
- `before_each` writes the inner init *and* asserts on the ready marker.
- `after_each` kills the tmux server and removes the tmpdir.
- The single `it` block has three logical steps (activate, run, repeat), each with a wait + an exact-content assertion.
- No `require("paneity")` from the test-runner side.
- No stubbed internal seams.

No file changes expected in this step — if you spot something wrong, fix it inline and re-run `make test` before committing.

- [ ] **Step 6.3: Stop**

The plan is complete when `make test` is green and the file matches the structure above. No final commit needed unless Step 6.2 surfaced a fix.
