# Prefill Delivery — TDD Redo

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `bind -x` + `C-x C-p` prefill chord with `tmux send-keys -l "<prefill>"` (literal text typed character-by-character into readline). This time we are writing a **strict integration test first** that asserts the prefill text appears at the exact prompt position via `capture-pane` — not a weak "is the file path somewhere on the screen" check.

**Why the previous attempt was insufficient:** The shipped Plan A fix used a weak assertion (`popup_text:find("sample.txt", 1, true)`) which would pass even if the prefill never reached the prompt — `sample.txt` could appear in the pane via any number of incidental means. The user reports "no prefilled command" in the field, and the test gave us no way to verify whether our fix actually helps.

**TDD shape:** Test first, watch it fail, apply the implementation, watch it pass. A single commit at the end with both the new test and the implementation change, so the test serves as a permanent guard.

**Tech Stack:** Lua, Neovim API, tmux, bash.

---

## File Map

**Modify:**
- `tests/integration/popup_command_spec.lua` — add a new dedicated test that asserts the prefill appears at the prompt position via strict `capture-pane` line matching
- `lua/paneity/shells/bash.lua` — switch prefill delivery from `bind -x` / `C-x C-p` to `tmux send-keys -l <prefill>`; remove the now-unused `__paneity_prefill_now` function, the `bind -x` registration, and the `-e PANEITY_PREFILL=...` env flag (the rcfile no longer reads it)

---

## Task 1: Write the strict prefill test FIRST

This step adds the new test without touching the implementation. Run the test suite after this step to confirm what happens against the current (bind -x) mechanism. Expected: the test may pass in our minimal test environment (where `bind -x` works), but the strict assertion documents what the field user experiences when the chord is intercepted. The point of the strict test is to give us a way to verify any future prefill mechanism change.

**Files:**
- Modify: `tests/integration/popup_command_spec.lua`

- [ ] **Step 1: Add the strict prefill placement test**

Append the following `it(...)` block inside the existing `describe("popup-shell command input", ...)` in `tests/integration/popup_command_spec.lua`, after the existing tests but before the closing `end)`.

```lua
  it("places the default prefill exactly at the prompt position", function()
    activate_paneity()

    session:send_keys("Space t c")
    assert.is_true(session:wait_for_popup_session(),
      "expected popup session within 3s")
    assert.is_true(session:wait_for_popup_prompt(),
      "expected popup bash prompt within 5s")

    -- The default prefill is the active buffer's relative path. In
    -- this spec the buffer is sample.txt (set in before_each via
    -- start_nvim({ file = sample_file })), so the prefill is the
    -- file name (sample.txt) -- nvim's cwd is wherever it was
    -- launched from, so :. resolves to the bare basename.
    --
    -- Strict assertion: the last non-blank line of the popup pane
    -- must be exactly "<PS1><prefill>" with the cursor at end.
    -- This rules out the case where the file path appears
    -- incidentally somewhere in the pane (scrollback, etc.).
    --
    -- We poll because the prefill is delivered asynchronously by a
    -- timer that fires after PROMPT_COMMAND signals readiness.
    local last_line
    local matched = vim.wait(3000, function()
      local text = session:popup_pane_text()
      last_line = nil
      for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("%S") then last_line = line end
      end
      if not last_line then return false end
      -- Trim trailing whitespace, then check for the literal pair.
      local trimmed = last_line:gsub("%s+$", "")
      return trimmed == "paneity_test> sample.txt"
    end, 50)

    assert.is_true(matched,
      "expected last popup line to be exactly 'paneity_test> sample.txt'; "
      .. "got: " .. tostring(last_line))

    -- Cancel so after_each can tear down cleanly.
    session:send_keys_to_popup("C-c")
    assert.is_true(session:wait_for_no_popup_session())
  end)
```

- [ ] **Step 2: Run the test against the current (bind -x) implementation**

```bash
make test 2>&1 | tail -40
```

Document the outcome:
- If the new test PASSES against current code: the `bind -x` mechanism delivers prefill correctly in our minimal fixture. That's expected — our test env doesn't replicate whatever the field user has that breaks the chord. The strict assertion still serves as a future regression guard.
- If the new test FAILS against current code: the `bind -x` mechanism is broken even in our env. Note the failure mode (most useful: what `last_line` ended up being).

Do NOT commit yet — Task 2 will apply the implementation change and the test + implementation get committed together.

---

## Task 2: Implement send-keys -l prefill delivery

Now flip the mechanism. After this task, the strict test from Task 1 must still pass — but now it's verified against the send-keys -l mechanism rather than bind -x.

**Files:**
- Modify: `lua/paneity/shells/bash.lua`

- [ ] **Step 1: Locate the prefill block in `get_command`**

```bash
grep -n "send-keys -t.*C-x C-p\|__paneity_prefill_now\|PANEITY_PREFILL" lua/paneity/shells/bash.lua
```

You will see lines like:
- The `bind -x '"\C-x\C-p": __paneity_prefill_now'` registration in the embedded RCFILE
- The `__paneity_prefill_now` function in the RCFILE
- `tmux send-keys -t %s:0.0 C-x C-p` in the Lua timer callback
- `-e PANEITY_PREFILL=...` in `env_flags`

- [ ] **Step 2: Replace the timer's send-keys call**

Find the prefill timer block inside `M.get_command`. Replace the existing call:

```lua
        tmux(string.format(
          "send-keys -t %s:0.0 C-x C-p", shesc(session_name)))
```

with:

```lua
        -- -l makes send-keys treat the argument as a literal string
        -- to type rather than tmux key names. Each char self-inserts
        -- via readline; no bind, no chord, no INPUTRC dependency.
        tmux(string.format(
          "send-keys -t %s:0.0 -l %s",
          shesc(session_name), shesc(prefill)))
```

`prefill` is the `get_command` parameter and is already in scope inside the timer closure.

- [ ] **Step 3: Remove the bind and function from the RCFILE**

Inside the embedded `RCFILE = [=[ ... ]=]` string, delete these lines (they are no longer used):

```bash
__paneity_prefill_now() {
  READLINE_LINE="$PANEITY_PREFILL"
  READLINE_POINT=${#PANEITY_PREFILL}
}
bind -x '"\C-x\C-p": __paneity_prefill_now'
```

- [ ] **Step 4: Remove `PANEITY_PREFILL` from env_flags**

The rcfile no longer references `$PANEITY_PREFILL`, so passing it is dead. Find this line in `M.get_command`:

```lua
    "-e PANEITY_PREFILL="  .. shesc(prefill or ""),
```

and delete it from the `env_flags` `table.concat` call.

- [ ] **Step 5: Update the comment above the prefill block (optional, for clarity)**

The current comment talks about C-x C-p / bind -x. Update it to describe the new mechanism:

```lua
  -- Prefill: poll for the ready marker, then type the prefill text
  -- literally into the helper session via `send-keys -l`. PROMPT_COMMAND
  -- writes the ready file before readline starts, so chars sent after
  -- that land in readline as self-insert.
```

- [ ] **Step 6: Run the module-load smoke check**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua local b = require('paneity.shells.bash'); assert(type(b.get_command) == 'function'); print('ok')" \
  -c "qa!"
```

Expected: `ok`.

- [ ] **Step 7: Run the full test suite**

```bash
make test
```

Expected: every test passes, including the strict prefill placement test from Task 1.

If the new strict test fails, debug:
- Is `prefill` actually non-empty when the timer fires? Add a `vim.notify("prefill=" .. vim.inspect(prefill))` inside the closure to verify.
- Is `shesc(prefill)` producing the right shell-escaped form? `vim.fn.shellescape("sample.txt")` returns `'sample.txt'`; the outer shell strips quotes and tmux receives `sample.txt` as the literal arg.
- Is `tmux send-keys -l` available on the installed tmux? Run `tmux send-keys -l "test"` manually to confirm.
- Is the ready file even being seen? Add a notify inside the polling check.

- [ ] **Step 8: Commit BOTH the test and the implementation in one commit**

```bash
git add tests/integration/popup_command_spec.lua lua/paneity/shells/bash.lua
git commit -m "Deliver popup prefill via send-keys -l (and assert prompt-line placement)"
```

---

## Constraints

- Pre-existing unstaged WIP in `tests/integration/core_workflow_spec.lua` and `tests/integration/support/tmux_session.lua` is intentionally preserved. Use the stash dance if you need to: `git stash push -- <those files>` before staging, `git stash pop` after.
- Only modify `tests/integration/popup_command_spec.lua` and `lua/paneity/shells/bash.lua`.

## Verification checklist

- [ ] The new "places the default prefill exactly at the prompt position" test passes.
- [ ] All other tests still pass (full `make test` is green).
- [ ] `grep -n "C-x C-p\|__paneity_prefill_now\|PANEITY_PREFILL=" lua/paneity/shells/bash.lua` returns nothing.
- [ ] `grep -n "send-keys.*-l" lua/paneity/shells/bash.lua` matches the timer line.
- [ ] The commit includes both the test and the implementation change.
