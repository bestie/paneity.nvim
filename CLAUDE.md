# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A small Neovim plugin (Lua) that drives a sibling **tmux** pane: pick a pane, send commands to it, re-run them, kill the previous foreground process before re-running, scroll the pane via copy-mode. See `README.md` for user-facing config.

There is no build step or linter wired up. Automated tests live under `tests/` and run via `make test` (see the **Testing** section below). For manual smoke-testing, open nvim under tmux → `:lua require("paneity").setup()` → exercise the keybindings.

## Architecture

Two source files matter:

- `plugin/paneity.lua` — loader stub. Sets `vim.g.paneity_loaded` and registers a `:TmuxPaneControl` user command for lazy loading. Real entry is `require("paneity").setup({...})` from the user's config.
- `lua/paneity/init.lua` — everything. The module table `M` holds **both** public API and persistent state (`M.target_pane_id`, `M.previous_command`, `M.last_paneity_command`, `M.config`). `setup()` is deliberately re-entrant: it preserves existing state on reload (`M.target_pane_id = M.target_pane_id or nil`). Don't refactor this state into locals without preserving that property.

`M.last_paneity_command` is the latest command paneity itself issued in the current target pane. It gates the termination escalation ladder (see below): paneity will only escalate beyond a single C-c against processes it started, and will only `kill -TERM` when the new command's normalized form matches it. Lifecycle: set in `M.run` after `send_command`, cleared lazily at the top of `_terminate_foreground` whenever `shell_is_foreground` is observed true, cleared eagerly when the target changes (`set_target_pane_id`, `M.toggle` disable).

`lua/paneity/utils.lua` exists but is **not required anywhere** — it's dead code (an older log/exec helper). Don't treat its conventions (e.g. relative `paneity.log` path, `vim.g.paneity_debug` flag) as authoritative; the live code in `init.lua` uses `/tmp/paneity.log` and `M.config.log_level`.

## How it talks to tmux

All tmux interaction goes through `shell_exec` → `io.popen` running `tmux ...` CLI commands. There's no libuv, no `vim.system`, no job control. Implications:

- Calls are **synchronous and blocking** on the Neovim main loop. Keep commands cheap.
- Output is captured as a string and trimmed; any structured data comes from `tmux ... -F '<format>'` (e.g. `pane_list_format` packs `index:id:pid:command` then is parsed with `string.match`).
- Pane targeting uses tmux **pane IDs** (`%N`, persistent across re-layout), not indices.

### Killing the previous process

`_terminate_foreground` runs a **gated escalation ladder**. Detection is PID-based (no name matching): the foreground process group id (`ps -o tpgid= -p <pane_pid>`) is compared against the pane's root PID (`#{pane_pid}`). When they match, the shell is idle; when they differ, some child is in the foreground. The helper `shell_is_foreground(pane_id)` wraps this. The pane's root PID is stable across `exec`, so something like `exec docker run -it ...` still produces a useful comparison.

The flow:

1. **Lazy clear.** If `shell_is_foreground` is true at entry, clear `M.last_paneity_command` (stale ownership state from a previous run). Then fall through — we still send C-c.
2. **C-c always.** Send `key_sequence[1]` (default `C-c`) unconditionally. At an idle prompt this is harmless and clears any partial command line; otherwise it interrupts the foreground process. Then `vim.wait` up to `step_timeout_ms` polling `shell_is_foreground`.
3. **Gate.** If shell hasn't returned and `M.last_paneity_command` is nil, return `false` — paneity didn't start whatever is running, so it won't escalate.
4. **Escalation loop.** Send each remaining entry in `key_sequence` (default just `C-\` = SIGQUIT), polling between each.
5. **Doubly-gated TERM.** If still no shell, AND `M.config.termination.send_term` is true, AND `normalize_command(new_command) == normalize_command(M.last_paneity_command)`, look up `tpgid` and `M._kill(tpgid, "TERM")`. The command-match guard means TERM only fires when the user is re-running the same command — replacing X with X, so killing the running X is acceptable. `normalize_command` collapses runs of whitespace and trims.
6. **UI prompt fallback.** If `_terminate_foreground` returned false, `M.run` calls `M._prompt_termination_choice` (synchronous `vim.fn.confirm` — chosen over `vim.ui.select` to avoid plugin overrides making the prompt async). Three choices: Type anyway, Cancel, kill -TERM. The TERM-from-prompt path is NOT gated on command match — the user has explicitly asked for it.

`kill_foreground(pane_id)` is a local helper used by both the TERM step in `_terminate_foreground` and the prompt's TERM branch in `M.run`. It does the `_pane_pid` → `_tty_foreground_pgid` → guard → `_kill` sequence.

Trade-off: a process that ignores both SIGINT and SIGQUIT AND that paneity didn't start will reach the prompt. The user explicitly opts into TERM (or types into the wedged process's stdin). This is intentional — paneity will not silently force-kill user-launched processes.

### Marker on the pane border

`mark_pane` reads the global `pane-border-format`, splices the marker in front of the first `#P`, and sets it as a **per-pane** option. `unmark_pane` restores the global value on that pane. `VimLeave` autocmd unmarks the current target. If you change the splice logic, remember the marker must be removable by re-applying the unmodified global format.

## UI selection

`choose_tmux_pane` builds a menu, prepends `"New pane"`, then tries `pcall(require, "fzf-lua")`. With fzf-lua available it uses `fzf_selection_ui` (which moves `"New pane"` to the **end** of the list — opposite of the native path). Without fzf-lua, it falls back to `vim.fn.inputlist` via `native_selection_ui`. Selection strings carry the pane id as `ID:%N`, parsed back out with `selection:match("ID:(%S+)")` — keep that token format if you touch either UI path.

## Public API surface

Exported on `M` and bound to keys by `setup_keybindings`: `toggle`, `set_target_pane`, `repeat_command`, `new_command(opts)`, `run(command)`, `up_enter`, `page_up`, `page_down`, `status_line`. `new_command` accepts `{ prompt, prefill, post_exec }` and is the documented way to trigger a run programmatically with a callback. `run(command)` is the lower-level public entry; it runs the termination ladder, handles the prompt fallback, and updates both `previous_command` and `last_paneity_command`. `repeat_command` routes through `M.run` (not `send_command` directly) so it inherits the full ladder + prompt + state-update behavior.

Keybinding config supports `keybindings = false` (disable all) or per-binding `false` (disable one). The merge is `vim.tbl_deep_extend("force", defaults, user)` — note this means a user passing a partial `keybindings` table gets the defaults filled in for omitted keys.

The `termination` config table (`M.defaults.termination`) exposes `key_sequence` (the send-keys ladder; entry 1 is unconditional, the rest are gated), `send_term` (enable/disable the TERM step), and `step_timeout_ms` (per-step `vim.wait` timeout).

## Testing

`make test` runs the full suite (unit + integration) under headless mise-managed Neovim. Both `nvim` and `tmux` are pinned in `mise.toml`; run `mise install` after a fresh clone. Tests use plenary.nvim's `PlenaryBustedDirectory`; plenary is cloned on demand into `deps/plenary.nvim` (gitignored).

Two suites:

- `tests/unit/` — fast, no real tmux. Stubs the internal seams (below) and asserts on recorded calls. Drives `_terminate_foreground` across the decision matrix (shell-idle, paneity-owned vs not, send_term on/off, command match vs not, whitespace normalization) and `M.run`'s prompt-fallback branches (Cancel, Type anyway, kill -TERM, prompt-not-shown-on-success). Also covers the state-lifecycle invariants for `last_paneity_command`.
- `tests/integration/` — spins up a private tmux server per test via `vim.env.TMUX_TMPDIR = $(mktemp -d)`. Both `vim.fn.system` calls in the test AND the plugin's `io.popen` calls inherit this env var, so all `tmux` invocations land on an isolated socket — the developer's real session is never touched. Cleanup runs `tmux kill-server` and removes the tmpdir. Three scenarios: SIGINT happy path (`sleep 30` started manually, C-c clears it), full SIGINT→SIGQUIT escalation ladder (nvim blocker started via `paneity.run` so the gate is satisfied), and the gate-blocks case (`bash my_script.sh` started manually — C-c reaches it, no escalation, prompt invoked).

### Test stub patterns

Unit tests use a `queue()` helper that feeds successive return values to a stubbed seam. **Important polling math:** with `step_timeout_ms = 5` and `vim.wait`'s default interval of 50ms, each `wait_for_shell` invocation calls the predicate twice (immediate + at-timeout). Combined with the initial `shell_is_foreground` call at the top of `_terminate_foreground` and the direct `_tty_foreground_pgid` call inside the TERM branch, queue lengths need to be sized accordingly. The `queue()` helper sticks on the last value once exhausted, so over-padding is harmless but mis-sizing leads to "passes for the wrong reason" silently.

### Internal seams for testability

Underscore-prefixed members on `M` are stubbable in unit tests. Production callers route through them too.

- `M._pane_pid(pane_id)` — wraps `tmux display -p '#{pane_pid}'`. Returns number or nil.
- `M._tty_foreground_pgid(pane_pid)` — wraps `ps -o tpgid= -p <pid>`. Returns number or nil. Has its own nil-guard on `pane_pid` so callers don't have to.
- `M._send_keys(pane_id, key)` — wraps `tmux send-keys -t %s '%s'`. **Always single-quotes the key**, so call sites pass bare `"C-c"` / `"C-\\"` — no embedded shell quoting in the caller.
- `M._kill(pid, signal)` — wraps `kill -SIG <pid>`. In production, always called with a numeric pid from `_tty_foreground_pgid` and the literal string `"TERM"`.
- `M._prompt_termination_choice()` — wraps `vim.fn.confirm` with the three-button prompt. Returns `"type"`, `"cancel"`, or `"term"`.
- `M._terminate_foreground(pane_id, new_command)` — the ladder itself; returns `true` if the shell is back in the foreground (ok to send the new command), `false` if the caller should fall back to the prompt. Takes `new_command` so the TERM gate can compare against `M.last_paneity_command`.

The underscore prefix marks them as "internal, may be replaced in tests."
