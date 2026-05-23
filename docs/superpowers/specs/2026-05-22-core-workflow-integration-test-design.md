# Core-workflow integration test

**Date:** 2026-05-22
**Status:** Approved (design)

## Problem

The existing integration suite (`tests/integration/terminate_foreground_spec.lua`)
covers `_terminate_foreground` against real tmux, but it drives `paneity` from
the **test-runner** nvim — `paneity.run(...)` is called as a Lua function and
the test never exercises pane selection, keybindings, or any of the
user-facing entry points. The "open a file in nvim, activate paneity, run a
command, repeat it" path that real users care about is currently untested
end-to-end.

This spec adds a single integration test that runs **real nvim inside real
tmux** and drives it via keystrokes, exercising the full default workflow
without stubbing any internal seams.

## Goals

- Cover the user-driven happy path: open file → activate → set & run → repeat.
- Exercise the public surface the user touches: `M.toggle`, `M.new_command`
  (via `vim.ui.input`), `M.repeat_command`.
- Exercise the keybinding layer (`<leader>tp`, `<leader>tc`, `<leader><leader>`).
- Drive everything via `tmux send-keys` against a real nvim — no paneity API
  called from the test harness; no internal seams stubbed.
- Keep the test self-contained: isolated tmux server, isolated tmpdir for the
  edited file and the per-run log file.

## Non-goals

- Multi-pane pane selection (the path through `fzf_selection_ui` /
  `native_selection_ui`). The test uses the single-pane auto branch in
  `choose_tmux_pane` so no selection UI is needed.
- Termination/escalation behavior. That's covered by the existing spec.
- The `up_enter`, `page_up`, `page_down`, `status_line` API surface.
- Custom-config paths (split direction/size, custom marker, disabled
  keybindings). Defaults only.

## Design

### Test architecture

A new file `tests/integration/core_workflow_spec.lua`, picked up by the
existing `PlenaryBustedDirectory` invocation in `make test`.

**Per-test isolation** matches the existing integration spec:

- `vim.env.TMUX_TMPDIR = mktemp -d` so the tmux server runs on a private
  socket and the developer's real session is untouched.
- `after_each` kills the tmux server and removes the tmpdir.

**Inside the tmux session**, the test spawns one pane that runs:

```
nvim --clean -u <inner_init> <file_to_edit>
```

- `--clean` skips user config / plugins so the test isn't sensitive to the
  developer's environment.
- `<inner_init>` is written into the tmpdir per-test (see below).
- `<file_to_edit>` is a small text file in the tmpdir, present so the test
  matches the user-described workflow ("open a file to edit"). Its contents
  don't matter to paneity; we just want a real buffer open.

The **test-runner nvim** never calls into `paneity` directly. It only:

- runs `tmux` via `vim.fn.system` (for setup, send-keys, list-panes,
  capture-pane),
- reads small files in the tmpdir for synchronization and verification.

### Inner init

Written to `<tmpdir>/init.lua`:

```lua
vim.opt.runtimepath:prepend("<repo_root>")
vim.g.mapleader = " "
require("paneity").setup({})
vim.schedule(function()
  vim.fn.writefile({ "ready" }, "<ready_marker_path>")
end)
```

Notes:

- `vim.g.mapleader` is set **before** `paneity.setup({})` because
  `<leader>...` mappings resolve mapleader at the time the keymap is created.
- `<Space>` as leader avoids backslash-escaping pain when sending the leader
  through tmux. The default `\` would force `'\\\\'`-style shell quoting.
- The ready marker is written under `vim.schedule` so we know setup has
  finished **and** the event loop is alive before the test starts driving
  keystrokes — that protects against racing the very first keystrokes
  against nvim's startup.
- `<repo_root>` is computed from the test file's location (mirroring
  `tests/minimal_init.lua`). Plenary is **not** added to the inner runtime
  path — paneity doesn't depend on it.

### Test flow

```text
1. Create tmpdir, log_file path, ready_marker path, file_to_edit, inner_init.
2. Start tmux server (TMUX_TMPDIR set) with one session, one pane running
   `nvim --clean -u <inner_init> <file_to_edit>`.
3. Wait for ready_marker to exist (timeout ~5s).
4. Assert: tmux list-panes for the session returns 1 pane.

5. Send `<Space>tp` to the nvim pane.
   → drives M.toggle → M.set_target_pane → choose_tmux_pane.
   → only one pane exists (excluding self), so the menu has just "New pane",
     bypassing fzf/native selection UIs. open_new_pane runs split-window.
6. Wait for tmux list-panes to return 2 panes (timeout ~3s).

7. Generate a random hex token (e.g. 16 hex chars).
8. Send `<Space>tc` to the nvim pane.
   → drives M.new_command → vim.ui.input opens a cmdline prompt.
9. Send `echo <TOKEN> >> <log_file>` followed by `Enter` to the nvim pane.
   → vim.ui.input callback fires → M.run → send_command tmuxes the command
     into the paneity-created pane → shell appends one line to log_file.
10. Wait until log_file has exactly 1 line equal to TOKEN (timeout ~5s).

11. Send `<Space><Space>` to the nvim pane.
    → drives M.repeat_command → M.run(M.previous_command).
12. Wait until log_file has exactly 2 lines, both equal to TOKEN
    (timeout ~5s).
```

### Synchronization signals

| What we're waiting for         | Signal                                   |
|--------------------------------|------------------------------------------|
| Inner nvim setup complete      | ready_marker file exists                 |
| New pane created               | `tmux list-panes` count == 2             |
| Command ran                    | log_file has 1 line                      |
| Repeat ran                     | log_file has 2 lines                     |

All polls use `vim.wait` (like the existing spec). Each assertion checks the
**exact** content of the log file — every line must equal TOKEN — so a stray
echo or shell prompt artifact ending up in the log fails the test loudly
instead of passing for the wrong reason.

### Random token

Generated in the test:

```lua
math.randomseed(os.time() + (os.clock() * 1e6))
local token = string.format("%08x%08x",
  math.random(0, 2^31 - 1), math.random(0, 2^31 - 1))
```

A fresh token per test run means: (a) we can't accidentally match content
from a previous test run, and (b) we're checking the specific command we
just sent, not noise.

### Sending the command text via send-keys

The command we want the inner nvim's `vim.ui.input` to receive is
`echo <TOKEN> >> <log_file>`. Sent as one tmux send-keys argument, each
character is sent as a keystroke; `>`, `/`, `_` are all literal keystrokes.
Shell-quoting handles the surrounding `tmux send-keys -t <pane> '...' Enter`
invocation.

### Why this exercises the right code paths

Driving via keybindings sent to a real nvim means:

- `M.toggle` is reached through its keymap (not via direct call).
- `choose_tmux_pane` runs for real: `os.getenv("TMUX_PANE")` works (we're
  inside tmux), `get_pane_info` parses tmux output, the "only one option"
  branch in `choose_tmux_pane` is exercised, `open_new_pane` actually splits
  the window.
- `M.set_target_pane_id` actually marks the pane border (we don't assert on
  this, but it runs).
- `M.new_command` actually invokes `vim.ui.input` — and the inner nvim is
  `--clean`, so we get the default implementation, not a plugin override.
- `M.run` runs the full ladder against an idle shell in the new pane (no
  foreground process to terminate), updates `M.previous_command` and
  `M.last_paneity_command`, and `send_command` tmuxes the keys.
- `M.repeat_command` reads `M.previous_command` from the same `M` table in
  the inner nvim's process and re-runs.

### Cleanup

`after_each`:

1. `tmux kill-server` — kills the inner nvim along with everything else.
2. `rm -rf <tmpdir>`.
3. Clear `vim.env.TMUX_TMPDIR`.

Unlike the existing spec we do **not** need to poke `require("paneity")
.target_pane_id = nil` on the test-runner module, because the test-runner
nvim never loaded paneity.

## Risks & mitigations

| Risk                                               | Mitigation                                                                                                          |
|----------------------------------------------------|---------------------------------------------------------------------------------------------------------------------|
| Inner nvim races startup against first keystrokes  | Wait for the `ready_marker` written from `vim.schedule`.                                                            |
| `vim.ui.input` prompt not yet open when we type    | `tmux send-keys` queues keystrokes atomically; nvim buffers them. The leader-c-t handler runs synchronously into the prompt. |
| Default leader gets escaped wrong through shells   | Use `<Space>` as leader, set in inner init before `paneity.setup({})`.                                              |
| Shell prompt or terminal init writes to log_file   | Command writes to log_file directly; we only count lines exactly equal to TOKEN.                                    |
| Slow CI: nvim takes >5s to start                   | Timeouts are conservative (5s for ready, 5s per command). Bump if flakes appear.                                    |
| Inner nvim leaks on test failure                   | `tmux kill-server` in `after_each` runs unconditionally.                                                            |

## Out of scope (deliberately)

- Asserting on the pane border marker. Visual; nothing tests it today.
- Asserting on `M.previous_command` / `M.last_paneity_command` directly.
  Those live in the inner nvim's process and aren't reachable from the
  test-runner without instrumentation; we infer correctness from
  `repeat_command` working.
- Coverage of `set_target_pane` when a target already exists. Initial
  `M.target_pane_id` is nil; `toggle` takes the activation branch.
- The fzf vs native selection UIs. Single-pane auto-branch avoids both.

## Acceptance

- `make test` passes locally and runs the new spec.
- The new spec fails if any of: pane isn't created, the first command
  doesn't run, the repeated command doesn't run, the log file accumulates
  any line that isn't TOKEN.
