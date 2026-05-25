# Popup Bash as Real Interactive Shell — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the popup bash render the same prompt the user sees in their day-to-day terminal. Two changes: pass `-i` so bash is unambiguously interactive (many `.bashrc` files short-circuit with `[[ $- == *i* ]] || return` when bash is launched without `-i`), and source the *interactive non-login* shell init files (`/etc/bash.bashrc` or `/etc/bashrc` followed by `~/.bashrc`) instead of the *login* chain (`/etc/profile` + `~/.bash_profile`).

**Why:** In the field, the popup prompt is unstyled — the user's PS1, colors, prompt framework, etc. are missing. Most likely cause: bash isn't detecting interactive mode, so `.bashrc` early-returns. Secondary: many distros put system-wide interactive prompt wiring in `/etc/bashrc` (macOS, RHEL) or `/etc/bash.bashrc` (Debian/Ubuntu), neither of which we source today.

This brings the popup in line with what a normal tmux pane opens (interactive non-login bash).

**Tech Stack:** Lua, Neovim API, tmux, bash.

**Spec it refines:** `docs/superpowers/specs/2026-05-24-popup-shell-input-design.md` (Bash adapter / rcfile section)

---

## File Map

**Modify:**
- `lua/paneity/shells/bash.lua` — pass `-i` in the bash argv; change the rcfile's "source user init" block from login-shell paths to interactive-shell paths

No test changes expected. The fixture `tests/integration/support/popup_home/.bashrc` is unconditional (no `[[ $- == *i* ]]` guard), so it continues to be sourced; the existing tests still pass.

## Trade-off (intentional)

Dropping `/etc/profile` and `~/.bash_profile` from the rcfile means env vars set ONLY in login-shell init files are no longer re-sourced. In practice the popup inherits all the env from nvim (which inherits from the user's login session), so this is rarely visible. If a user relies on something that ONLY exists when `.bash_profile` runs at popup-launch, they should move that thing to `.bashrc` (matching how every other tmux pane on their system works).

A future opt-in to behave as a login shell is out of scope for this plan.

---

## Task 1: Pass `-i` and source interactive-shell init

**Files:**
- Modify: `lua/paneity/shells/bash.lua`

- [ ] **Step 1: Locate the bash invocation**

```bash
grep -n "bash --rcfile\|new-session.*bash" lua/paneity/shells/bash.lua
```

The relevant line is inside `M.get_command`, building the `tmux new-session` command. It currently looks like:

```lua
  local _, code = tmux(string.format(
    "new-session -d -s %s -x 200 -y 50 %s bash --rcfile %s",
    shesc(session_name), env_flags, shesc(rcfile_path)))
```

- [ ] **Step 2: Add `-i` to the bash invocation**

Change `bash --rcfile %s` to `bash -i --rcfile %s`. The line becomes:

```lua
  local _, code = tmux(string.format(
    "new-session -d -s %s -x 200 -y 50 %s bash -i --rcfile %s",
    shesc(session_name), env_flags, shesc(rcfile_path)))
```

`-i` makes bash unambiguously interactive even with `--rcfile`. With `-i`, `$-` contains `i`, so user bashrc guards like `[[ $- == *i* ]] || return` evaluate true and the prompt customization runs.

- [ ] **Step 3: Locate the rcfile's user-init source block**

Inside the embedded `RCFILE = [=[ ... ]=]`, the first three lines source the user's init:

```bash
[ -r /etc/profile ]    && . /etc/profile
[ -r ~/.bash_profile ] && . ~/.bash_profile
[ -r ~/.bashrc ]       && . ~/.bashrc
```

- [ ] **Step 4: Replace with interactive-shell init paths**

Replace the three lines above with:

```bash
[ -r /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -r /etc/bashrc ]      && . /etc/bashrc
[ -r ~/.bashrc ]        && . ~/.bashrc
```

Rationale: this is what an interactive non-login bash sources naturally — the same files your shell reads when you open a new tmux pane. `/etc/bash.bashrc` is the Debian/Ubuntu system-wide interactive init; `/etc/bashrc` is the macOS/RHEL equivalent; on most systems only one of the two exists.

- [ ] **Step 5: Verify the module loads**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua local b = require('paneity.shells.bash'); assert(type(b.get_command) == 'function'); print('ok')" \
  -c "qa!"
```

Expected: `ok`.

- [ ] **Step 6: Run all tests**

```bash
make test
```

Expected: 22/22 pass. The fixture `tests/integration/support/popup_home/.bashrc` does not have an interactive guard, so it's still sourced and the `paneity_test>` PS1 still appears.

- [ ] **Step 7: Commit**

```bash
git add lua/paneity/shells/bash.lua
git commit -m "Run popup bash with -i and source interactive-shell init"
```

---

## Constraints

- Modify ONLY `lua/paneity/shells/bash.lua`.
- The pre-existing unstaged WIP in `tests/integration/` is intentionally preserved. Do not touch it.

## Verification checklist

- [ ] `make test` is fully green.
- [ ] `grep -n "bash -i --rcfile" lua/paneity/shells/bash.lua` matches the invocation line.
- [ ] `grep -n "/etc/profile\|bash_profile" lua/paneity/shells/bash.lua` returns nothing.
- [ ] `grep -n "/etc/bash.bashrc\|/etc/bashrc" lua/paneity/shells/bash.lua` matches the new init block.

## Manual verification recommendation

After merging, the user should open a popup against their real environment and confirm:
- The prompt matches what they see in a normal tmux pane (`echo $PS1` inside the popup is helpful for debugging).
- `$-` inside the popup contains `i` (verify by running `echo $-` and pressing Enter).
- Their normal aliases / completions work.
