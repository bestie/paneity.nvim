# Robust foreground-process termination

**Date:** 2026-05-12
**Status:** Approved (design)

## Problem

`_terminate_foreground` currently early-returns when `pane_current_command`
matches a hard-coded `SHELLS = { bash, zsh, fish, sh, dash }` table. Name-based
detection is wrong in two common situations:

- **`bash my_script.sh`** — tmux reports `pane_current_command = "bash"`,
  identical to an idle interactive bash prompt. paneity skips termination, and
  the next command is typed into the script's stdin. Demonstrated by
  `tests/integration/terminate_foreground_spec.lua` ("known limitation").
- **Anything that wraps a shell** (e.g. `docker run -it`) — the host-side
  command name (`docker`) isn't in SHELLS, so the detector falls through to
  termination by accident, not by design.

Beyond the name check, the escalation ladder is also blunt: it sends
`C-c → C-c → C-\\` regardless of whether paneity started the foreground
process, so a user-launched build that ignores SIGINT can be SIGQUIT'd by a
paneity action it had nothing to do with.

## Goals

- Replace name-based shell detection with a robust signal that distinguishes
  "the pane's root process is idle" from "a child process is running."
- Make escalation conservative: only force-kill processes paneity actually
  owns, and only TERM when the user is clearly asking for a fresh instance
  of the same command.
- Surface an explicit choice to the user when paneity refuses to escalate,
  rather than silently corrupting state by typing into a wedged process.
- Keep the implementation testable via the existing internal-seam pattern.

## Non-goals

- Detecting nested terminal multiplexing layers (e.g. a script running
  inside `docker exec`). The new design treats anything below `pane_pid` as
  "running" — which is correct for paneity's purpose.
- Per-program first-key selection (the former REPL → C-d branch). Users who
  need it can construct their own `key_sequence`.
- Cross-platform support beyond Linux + macOS (both expose `ps -o tpgid=`).

## Design

### Detection: tty foreground process group

The single signal is the **foreground process group ID on the pane's tty**:

```
tpgid = ps -o tpgid= -p <pane_pid>
```

`pane_pid` comes from tmux's `#{pane_pid}` and is the PID of the first
process tmux launched in the pane. It is stable across `exec` (since `exec`
preserves PID) and across the process running children, since tmux doesn't
update it.

A new helper `shell_is_foreground(pane_id)` returns true iff
`tpgid == pane_pid`. Semantically: "no child of the pane's root process is
currently in the foreground."

This handles every case the name check got wrong:

| Situation | `pane_pid` | tpgid | `shell_is_foreground` |
| --- | --- | --- | --- |
| Idle bash prompt | bash PID | bash PID | true |
| `bash my_script.sh` from bash | bash PID | child bash PID | false |
| `docker run -it ubuntu bash` | bash PID | docker PID | false |
| Idle bash inside `docker run -it` | docker PID | docker PID | true |
| REPL like `irb` | bash PID | irb PID | false |

`shell_is_foreground` is consulted in two places: the wait loop after each
escalation step (did the shell come back?), and the lazy clear of
`last_paneity_command` at the top of `M.run`. It is *not* used to decide
whether to send the first C-c — that send is unconditional, so the REPL
case folds into the general "interrupt the foreground" path without
needing special-case handling.

### Termination ladder

`M.run(new_command)` performs the following steps in order:

1. **C-c always.** Send `C-c` (the first entry in `key_sequence`). Wait up to
   `step_timeout_ms` for `shell_is_foreground` to become true. C-c at an
   idle shell prompt is a harmless no-op that also clears any partially
   typed command — eliminating the "skip termination if it looks like a
   shell" branch entirely.

2. **Gated escalation key.** If the shell hasn't returned AND paneity owns
   the foreground (`M.last_paneity_command ~= nil`): send the next entry in
   `key_sequence` (default `C-\\` → SIGQUIT). Wait again. Repeat for any
   further entries in `key_sequence`.

3. **Doubly-gated TERM.** If the shell still hasn't returned, paneity owns
   the foreground, `send_term` is enabled, AND the new command's normalized
   form equals the current value of `M.last_paneity_command` normalized
   (i.e. the command paneity issued last, before this `run` overwrites it):
   read the current `tpgid` and send `kill -TERM <tpgid>`. Wait.

   "Normalized" means whitespace-collapsed and trimmed:
   `s:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")`. `make test ` and
   `make test` match; `make test` and `make test -v` do not.

4. **User prompt.** If the shell still hasn't returned after all permitted
   escalation, surface a synchronous UI prompt via `vim.ui.select`:
   - **Type anyway** — send the new command into whatever is in the
     foreground.
   - **Cancel** — abort without sending.
   - **kill -TERM** — `kill -TERM <tpgid>`, then send the new command
     regardless of whether the shell returned.

5. **Send the command.** Once the shell is back (or the user picked
   "Type anyway"), send the new command and set
   `M.last_paneity_command = new_command`.

### State

A single scalar `M.last_paneity_command` tracks the command paneity issued.
paneity targets one pane at a time, so per-pane keying isn't required.

Lifecycle:

- **Set** in `M.run()` immediately after `send_command` succeeds.
- **Cleared lazily** whenever paneity observes `shell_is_foreground == true`
  at the start of a paneity action. No background polling — the check that
  already happens during the step-1 C-c wait does double duty.
- **Cleared eagerly** when `set_target_pane_id` changes the target.

The lazy clear is what prevents the gate from going stale across
user-initiated commands. Concretely: paneity runs `rspec`, it finishes,
shell returns. The user manually starts `vim`. Next paneity call: the
opening C-c wait observes `shell_is_foreground` was true at some point
since the last `run()` — but only via the *first* observation, which is
the one that nil's the state. So by the time we evaluate the gate at
step 2, `last_paneity_command` is nil and we treat vim as user-owned.

Implementation note: the lazy clear has to happen on the *first* observed
shell state, not the post-C-c state, otherwise sending C-c to a wedged
non-paneity process would never clear (because shell never returns) — which
is correct — but if the shell *was* returned before we sent C-c, we'd miss
the clear. The cleanest place is a single check at the top of
`_terminate_foreground` before sending anything.

### Configuration

A new `termination` table in `M.defaults`:

```lua
termination = {
  key_sequence    = { "C-c", "C-\\" },
  send_term       = true,
  step_timeout_ms = 200,
}
```

- `key_sequence` — ordered list of `send-keys` arguments. Index 1 is sent
  unconditionally; indexes 2..N are sent only behind the paneity-owns gate.
- `send_term` — enables the `kill -TERM` step (still gated on
  command-match).
- `step_timeout_ms` — wait between escalation steps, passed to `vim.wait`.

User overrides merge via the existing `vim.tbl_deep_extend("force", ...)`
path in `setup()`.

### Module surface

Public:
- `M.run(command)` — gains the UI prompt branch; otherwise same shape.

Internal seams (underscore-prefixed; testable, swappable):
- **New:** `M._tty_foreground_pgid(pane_pid)` — wraps
  `ps -o tpgid= -p <pid>`; returns number or nil.
- **New:** `M._kill(pid, signal)` — wraps `kill -SIG <pid>`.
- **Changed:** `M._terminate_foreground(pane_id, new_command)` — takes the
  new command for the TERM gate; returns `true` (shell returned, ok to
  send) or `false` (caller must prompt).
- **Removed:** `SHELLS` and `REPLS` tables. No name matching anywhere.

`M._pane_current_command`, `M._send_keys` are unchanged.

`get_pane_info` already parses `pane_pid` per row but doesn't use it; the
new code threads it through where needed. (`pane_pid` can also be fetched
on demand via `tmux display -p -t <id> '#{pane_pid}'` if it's cleaner at
the call site.)

## Testing

### Unit (`tests/unit/`)

Stub `M._tty_foreground_pgid`, `M._send_keys`, `M._kill`, and a fake
`vim.wait`. Drive each branch:

- shell-already-foreground → no keys sent, returns true, clears state.
- C-c returns shell → only C-c sent, returns true.
- C-c fails + paneity owns + key_sequence has C-\\ → both sent, C-\\ wins.
- C-c fails + paneity owns + command match + send_term=true → C-\\ then TERM.
- C-c fails + paneity *doesn't* own → only C-c sent, returns false.
- C-c fails + paneity owns + command does *not* match → no TERM, returns false.
- C-c fails + paneity owns + send_term=false → no TERM, returns false.
- Whitespace normalization: `"make test "` vs `"make test"` matches.

### Integration (`tests/integration/`)

- **Flip the known-limitation test** (`bash my_script.sh`): change the
  trap log assertion from `{ "READY" }` to `{ "READY", "SIGINT" }`. Drop
  the `(known limitation)` suffix and update the test description.
- **Existing happy-path SIGINT test** keeps passing unchanged.
- **Existing SIGQUIT escalation test** keeps passing — but note: the
  escalation now requires paneity to own the foreground. The test does
  `paneity.run(...)` to start the nvim blocker, so `last_paneity_command`
  is set and the gate is satisfied. No change needed.
- **New: user-launched process is not escalated.** Manually start
  `sleep 30` via tmux send-keys (NOT via `paneity.run`), call
  `paneity.run("echo X")`, assert that `_terminate_foreground` returned
  false (or that the UI prompt was invoked — whichever is easier to assert
  headlessly; likely intercept `vim.ui.select` and record the call).

## Implementation notes

- `shell_is_foreground(pane_id)` is a local helper that fetches `pane_pid`
  once and compares it to `M._tty_foreground_pgid(pane_pid)`. The seam stays
  low-level (just the `ps` call) so unit tests can stub it directly.
- The UI prompt uses `vim.ui.select`, which is synchronous in default
  Neovim — fine here since the rest of paneity is already synchronous on
  the main loop. No nested `vim.wait` during the prompt.

## Migration / compatibility

- Existing user configs work unchanged — `termination` is additive with
  defaults.
- The default behavior changes in two visible ways:
  1. C-c is sent on every `M.run`, including at idle prompts. Pane output
     gets one `^C` line per run.
  2. SIGQUIT escalation now only fires for paneity-issued commands.
     Previously it would fire for any non-shell foreground.
- TODO.md → strike "Name-based shell detection misses `bash my_script.sh`".
