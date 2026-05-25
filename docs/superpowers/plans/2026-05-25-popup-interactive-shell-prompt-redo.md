# Interactive Bash Popup — TDD Redo

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the popup bash a proper interactive shell that sources the same system + user init files an ordinary tmux pane reads. Two changes: pass `-i` so `$-` unambiguously contains `i`, and source `/etc/bash.bashrc` / `/etc/bashrc` / `~/.bashrc` (the interactive non-login chain) instead of `/etc/profile` / `~/.bash_profile` / `~/.bashrc` (the login chain).

**Why the previous attempt was insufficient:** The shipped Plan B fix didn't have a test that actually verifies "the popup bash is interactive enough to run code guarded by `[[ $- == *i* ]]`". The existing `wait_for_popup_prompt` greps for `paneity_test>` in the pane, but the fixture sets PS1 unconditionally — so the prompt appears whether or not bash is in interactive mode. The user reports the prompt isn't styled in the field; we have no test that pins down the interactivity guarantee.

**TDD shape:** Move the fixture's PS1 (and the rest of its body) behind an interactive guard. With the guard in place, the existing prompt-style assertion is meaningful: the fixture PS1 appears only when bash is interactive. Run the test, observe whether it fails on current (no `-i`, login-chain) code, then apply the fix.

**Tech Stack:** Lua, Neovim API, tmux, bash.

---

## File Map

**Modify:**
- `tests/integration/support/popup_home/.bashrc` — wrap the body in an interactive guard (`case $- in *i*) ;; *) return;; esac`)
- `lua/paneity/shells/bash.lua` — pass `-i` to the bash invocation; switch the rcfile's system/user init chain from login paths (`/etc/profile`, `~/.bash_profile`) to interactive paths (`/etc/bash.bashrc`, `/etc/bashrc`)

---

## Task 1: Strengthen the fixture (test-first)

Add an interactive guard to the fixture `.bashrc` so its PS1 / aliases / markers ONLY apply if bash is interactive. With this in place, the existing assertions that grep for `paneity_test>` only succeed when bash inside the popup is truly interactive.

**Files:**
- Modify: `tests/integration/support/popup_home/.bashrc`

- [ ] **Step 1: Add the guard at the top of the fixture .bashrc**

Replace the current content of `tests/integration/support/popup_home/.bashrc` with:

```bash
# Fixture .bashrc used by paneity integration tests.
# When a test points $HOME at tests/integration/support/popup_home,
# the popup-shell launches a bash that sources this file. Assertions
# can then check for these markers to confirm user init was sourced.

# Interactive guard. Real users often have this same shape in their
# .bashrc (`[[ $- == *i* ]] || return`). If our popup bash is NOT
# detected as interactive, this returns before any PS1 / alias /
# marker is set, and tests that look for the fixture PS1 time out.
case $- in
  *i*) ;;
  *)   return ;;
esac

export PANEITY_TEST_MARKER=1
alias ptest='echo PTEST'

# A known, plain PS1 so capture-pane assertions can grep for the prompt
# without dealing with the developer's local PS1 styling.
PS1='paneity_test> '
```

- [ ] **Step 2: Run the test suite against the current (no `-i`, login-chain) implementation**

```bash
make test 2>&1 | tail -40
```

Document the outcome:

- **If tests now FAIL** (specifically `wait_for_popup_prompt` timing out across multiple specs because `paneity_test>` never appears): the guard demonstrates the bug — bash inside our popup wasn't interactive, and the user's init was being short-circuited. This is the TDD red state we want before applying the fix.
- **If tests still PASS**: bash inside our popup is already interactive (likely because tty-on-stdin auto-detection works for `bash --rcfile FILE`). The `-i` change in Task 2 is then defensive rather than load-bearing, and the load-bearing fix in this plan is the `/etc/bash.bashrc` / `/etc/bashrc` switch — which directly addresses the "prompt not styled" complaint (user's system-wide interactive init lives there and we weren't sourcing it).

Either outcome is informative. Note which case you observed.

Do NOT commit yet — Task 2 applies the implementation change and they get committed together.

---

## Task 2: Apply `-i` and the interactive-chain init

**Files:**
- Modify: `lua/paneity/shells/bash.lua`

- [ ] **Step 1: Locate the bash invocation**

```bash
grep -n "bash --rcfile" lua/paneity/shells/bash.lua
```

You should see one match inside `M.get_command`, building the `tmux new-session` command:

```lua
  local _, code = tmux(string.format(
    "new-session -d -s %s -x 200 -y 50 %s bash --rcfile %s",
    shesc(session_name), env_flags, shesc(rcfile_path)))
```

- [ ] **Step 2: Pass `-i` AFTER `--rcfile`**

Change `bash --rcfile %s` to `bash --rcfile %s -i`. The final line:

```lua
  local _, code = tmux(string.format(
    "new-session -d -s %s -x 200 -y 50 %s bash --rcfile %s -i",
    shesc(session_name), env_flags, shesc(rcfile_path)))
```

> Important: `-i` must come AFTER `--rcfile FILE`. Bash 5.2 (and likely other versions) refuses `bash -i --rcfile FILE` because the parser treats `--` (the long-option marker, parsed greedily even mid-flag) as end-of-options once `-i` has been consumed, then errors on the dangling `--rcfile`. The empirically-correct order is `--rcfile FILE` first, `-i` last. Verified by running `bash -i --rcfile /dev/stdin <<<exit` versus `bash --rcfile /dev/stdin -i <<<exit`.

- [ ] **Step 3: Locate the system/user init source block in the RCFILE**

Inside the embedded `RCFILE = [=[ ... ]=]` string, the first three lines source the user's init:

```bash
[ -r /etc/profile ]    && . /etc/profile
[ -r ~/.bash_profile ] && . ~/.bash_profile
[ -r ~/.bashrc ]       && . ~/.bashrc
```

- [ ] **Step 4: Replace with interactive non-login init paths**

Replace those three lines with:

```bash
[ -r /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -r /etc/bashrc ]      && . /etc/bashrc
[ -r ~/.bashrc ]        && . ~/.bashrc
```

Rationale: this is what an interactive non-login bash sources naturally — the same files your shell reads when you open a new tmux pane. `/etc/bash.bashrc` is the Debian/Ubuntu system-wide interactive init; `/etc/bashrc` is the macOS/RHEL equivalent. On most systems only one of the two exists. `/etc/profile` and `~/.bash_profile` are login-shell files and don't belong here.

- [ ] **Step 5: Run the module-load smoke check**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua local b = require('paneity.shells.bash'); assert(type(b.get_command) == 'function'); print('ok')" \
  -c "qa!"
```

Expected: `ok`.

- [ ] **Step 6: Run the full test suite**

```bash
make test
```

Expected: every test passes. In particular: the existing tests that grep for `paneity_test>` (`wait_for_popup_prompt`, the "sources the user's bashrc" test) now succeed because:
1. Bash is unambiguously interactive (the `-i` flag), so the guard you added in Task 1 passes.
2. The fixture's PS1 / alias / marker are set, and the prompt appears.

If a test fails, debug:
- Inspect `tmux capture-pane -t paneity-popup-...:0.0 -p` during a test run (insert a `vim.notify(session:popup_pane_text())` in the test).
- If the popup shows bash's default PS1 (e.g. `bash-5.2$ `), the guard returned and the fixture wasn't sourced → `-i` isn't taking effect; double-check the argv order.
- If the popup shows nothing at all, suspect the new system init (`/etc/bashrc`) on the test machine is doing something weird — but the `[ -r ... ] &&` guard protects against missing files, not against files that misbehave.

- [ ] **Step 7: Commit BOTH the fixture change and the implementation in one commit**

```bash
git add tests/integration/support/popup_home/.bashrc lua/paneity/shells/bash.lua
git commit -m "Run popup bash with -i and source interactive-shell init"
```

---

## Constraints

- Pre-existing unstaged WIP in `tests/integration/core_workflow_spec.lua` and `tests/integration/support/tmux_session.lua` is intentionally preserved. Use the stash dance if needed.
- Only modify `tests/integration/support/popup_home/.bashrc` and `lua/paneity/shells/bash.lua`.

## Verification checklist

- [ ] `make test` is fully green.
- [ ] The fixture `.bashrc` has the interactive guard at the top, before any PS1 / alias / marker.
- [ ] `grep -n "bash --rcfile.*-i$" lua/paneity/shells/bash.lua` matches the invocation line.
- [ ] `grep -n "/etc/profile\|bash_profile" lua/paneity/shells/bash.lua` returns nothing.
- [ ] `grep -n "/etc/bash.bashrc\|/etc/bashrc" lua/paneity/shells/bash.lua` matches both new init lines.

## Manual verification recommendation

After merging, run the popup against your real environment:
- Confirm the prompt matches what you see in a normal tmux pane (`echo $PS1` inside the popup is a quick check).
- Confirm `$-` inside the popup contains `i` (run `echo $-`).
- Confirm `[ -r /etc/bashrc ] && echo yes` (or `/etc/bash.bashrc`) prints `yes` if your system has the file.
