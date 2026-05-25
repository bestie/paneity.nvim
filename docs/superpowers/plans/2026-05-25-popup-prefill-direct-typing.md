# Prefill Delivery via Direct Typing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current `bind -x` + `C-x C-p` prefill mechanism with `tmux send-keys -l <prefill>`, which types the prefill text directly into readline. Eliminates the dependency on a specific key chord that can be intercepted by the user's INPUTRC or readline mode.

**Why:** In the field, the prefill never appears for the real user. The most likely cause is that `C-x C-p` is intercepted by their setup (custom INPUTRC, vi-mode, prompt frameworks). Direct literal typing via `send-keys -l` bypasses key bindings entirely — each character goes through readline as self-insert.

**Tech Stack:** Lua, Neovim API, tmux, bash.

**Spec it refines:** `docs/superpowers/specs/2026-05-24-popup-shell-input-design.md` (Prefill delivery section)

---

## File Map

**Modify:**
- `lua/paneity/shells/bash.lua` — change the prefill timer callback; remove the now-unused `bind -x '"\C-x\C-p"'` and `__paneity_prefill_now` from the embedded RCFILE

No test changes expected (the existing integration test asserts `popup_text:find("sample.txt", 1, true)` on the popup pane, which is satisfied by either delivery mechanism).

---

## Task 1: Switch prefill delivery to literal typing

**Files:**
- Modify: `lua/paneity/shells/bash.lua`

- [ ] **Step 1: Read the current `get_command` to locate the prefill block**

```bash
grep -n "send-keys -t.*C-x C-p\|__paneity_prefill_now\|paneity_prefill" lua/paneity/shells/bash.lua
```

You should see (line numbers approximate):
- The `bind -x '"\C-x\C-p": __paneity_prefill_now'` line in the embedded RCFILE
- The `__paneity_prefill_now` function in the RCFILE
- The `tmux send-keys -t %s:0.0 C-x C-p` call in the prefill timer block

- [ ] **Step 2: Replace the timer's send-keys call**

Find the prefill timer block inside `M.get_command`. It currently contains a line like:

```lua
        tmux(string.format(
          "send-keys -t %s:0.0 C-x C-p", shesc(session_name)))
```

Replace it with:

```lua
        -- -l makes send-keys treat the argument as a literal string to
        -- type rather than as tmux key names. Each char self-inserts
        -- via readline; no bind, no chord, no INPUTRC dependency.
        tmux(string.format(
          "send-keys -t %s:0.0 -l %s",
          shesc(session_name), shesc(prefill)))
```

Note: `prefill` is the closure variable on `get_command`; it's already in scope.

- [ ] **Step 3: Remove the now-unused bind and function from the RCFILE**

Inside the embedded `RCFILE = [=[ ... ]=]` string, remove these lines (they are no longer used):

```bash
__paneity_prefill_now() {
  READLINE_LINE="$PANEITY_PREFILL"
  READLINE_POINT=${#PANEITY_PREFILL}
}
bind -x '"\C-x\C-p": __paneity_prefill_now'
```

Leave `PANEITY_PREFILL` as a defined env var — even if unused inside bash, it makes the Lua-side handling self-documenting.

Actually: `PANEITY_PREFILL` is no longer referenced by the rcfile. You can remove the `-e PANEITY_PREFILL=...` line from `env_flags` in `M.get_command` too. Do this. Update the comment near `env_flags` if it specifically calls out PANEITY_PREFILL.

- [ ] **Step 4: Verify the module loads**

```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "lua local b = require('paneity.shells.bash'); assert(type(b.get_command) == 'function'); print('ok')" \
  -c "qa!"
```

Expected: `ok`.

- [ ] **Step 5: Run all tests**

```bash
make test
```

Expected: 22/22 pass. The headline integration test (`captures a command typed in the popup and runs it in the target`) still asserts `popup_text:find("sample.txt", 1, true)`, which now passes via direct typing instead of bind -x.

If the headline test fails because the prefill arrives but with shell escaping artefacts (e.g. backslashes from `vim.fn.shellescape`), inspect what `send-keys -l ARG` actually injected by capturing the popup pane during a manual run. Most likely fix: `prefill` should pass through `shesc` exactly as before, since send-keys treats `-l ARG` as a literal string per arg, not per character — `shesc` only escapes for the shell that invokes tmux, not for the tmux client.

- [ ] **Step 6: Commit**

```bash
git add lua/paneity/shells/bash.lua
git commit -m "Use send-keys -l for prefill delivery instead of bind -x chord"
```

---

## Constraints

- Modify ONLY `lua/paneity/shells/bash.lua`.
- The `PROMPT_COMMAND`-driven ready file mechanism stays — we still need to know when bash is at the prompt before sending the prefill. Only the trigger keystroke changes.
- The pre-existing unstaged WIP in `tests/integration/` is intentionally preserved. Do not touch it.

## Verification checklist

- [ ] `make test` is fully green.
- [ ] `grep -n "C-x C-p\|__paneity_prefill_now" lua/paneity/shells/bash.lua` returns nothing.
- [ ] The committed diff is small (single function-internal change + a few rcfile line deletions + one env_flags line removal).
