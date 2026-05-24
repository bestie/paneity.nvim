# Popup-shell command input

## Problem

`M.new_command` currently reads the command to send to the target pane via `vim.ui.input`. That widget has no shell-aware completion, no filename completion, no alias expansion preview, no history — every prior command has to be retyped from memory. The user wants the input experience to feel like a normal interactive bash shell: tab completion for paths and subcommands, the same aliases and functions that exist in their day-to-day terminal, and a history that is paneity's own (not polluted by, and not polluting, their main shell history).

## Approach

Replace the `vim.ui.input` call inside `M.new_command` with a tmux popup that runs a real bash shell. The popup's Enter key is rebound so the command is captured to a file and bash exits before the command can run. Paneity reads the captured command and feeds it to the existing `M.run` path — the rest of the plugin (termination ladder, `previous_command`, `last_paneity_command`) is unchanged.

Bash is the only adapter implemented in v1, but the boundary between core and shell is a single-method strategy interface so adding zsh or fish later requires no core changes.

## Architecture

```
nvim keybinding → M.new_command(opts)
   ↓ resolve prefill (default: current buffer file relative to cwd)
shells[M.config.shell].get_command(prefill, cb)
   ↓ adapter mechanics (popup, rcfile, capture)
   ↓ user types with full shell completion, presses Enter
cb(command_string | nil)
   ↓ on success
M.run(command)
```

The core module never sees a tmux popup, an rcfile, or a capture file. Everything between "we need a command" and "here is a command" is the adapter's concern.

### File layout

```
lua/paneity/
  init.lua                  # existing core; M.new_command body changes
  shells/
    init.lua                # registry: { bash = require("paneity.shells.bash") }
    bash.lua                # bash adapter (popup, rcfile, capture)
```

The rcfile contents live as a Lua multi-line string inside `bash.lua`; no external script files.

## Shell strategy interface

Each adapter implements one async method:

```lua
-- lua/paneity/shells/bash.lua
local M = {}

-- Async. Calls cb(command_string) on success, cb(nil) on cancel.
function M.get_command(prefill, cb)
  -- popup + rcfile + capture mechanics, entirely encapsulated
end

return M
```

No `available()` probe. If `M.config.shell` names something not installed, the popup fails and the user sees the error — same failure mode as any other misconfiguration.

## Bash adapter

### Popup addressing via a detached helper session

`tmux display-popup -E "<command>"` running a command directly does not give the command a stable tmux target — the popup is not a regular pane. To get an addressable target (needed for both prefill delivery and integration testing), the adapter launches the shell inside a detached single-pane session, then opens the popup as a thin `attach-session` viewer:

```text
1. Generate session name:   paneity-popup-<pid>-<rand>
2. tmux new-session -d -s <name> -x <W> -y <H> \
      -e PANEITY_PREFILL=…  -e PANEITY_CAPTURE=…  -e PANEITY_HISTFILE=… \
      -e PANEITY_READY=…    -e PANEITY_CWD=…       \
      bash --rcfile <rcfile>
3. tmux display-popup -E "tmux attach-session -t <name>"
4. (parallel, if prefill non-empty) poll for $PANEITY_READY;
   once present → tmux send-keys -t <name>:0.0 C-x C-p
5. On display-popup exit:
     read $PANEITY_CAPTURE → command or empty;
     unlink temp files, kill session if still alive;
     cb(command) or cb(nil)
```

When bash exits (Enter triggers capture-and-exit), the session loses its only pane and tmux destroys it; `attach-session` returns; `display-popup -E` returns; the on-exit callback fires.

The session name is the addressable handle. The adapter stores it on `shells/bash.lua`'s `M._active_session` field (cleared after popup close) so integration tests can target it without polling `tmux list-sessions`.

### The rcfile

Generated per invocation to a tempfile. Sources the user's full init first, then layers paneity overrides on top:

```bash
# 1. User's full environment — aliases, completions, prompt, everything
[ -r /etc/profile ]    && . /etc/profile
[ -r ~/.bash_profile ] && . ~/.bash_profile
[ -r ~/.bashrc ]       && . ~/.bashrc

# 2. Paneity overrides (must come AFTER user init)
cd "$PANEITY_CWD" 2>/dev/null || true

export HISTFILE="$PANEITY_HISTFILE"
export HISTSIZE=1000
export HISTFILESIZE=1000
history -c
history -r

# Capture: write current readline buffer to capture file and exit cleanly.
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

# Cancel: missing capture file is the no-op sentinel.
trap 'exit 130' INT

# Prefill: insert $PANEITY_PREFILL into the readline buffer when triggered.
__paneity_prefill_now() {
  READLINE_LINE="$PANEITY_PREFILL"
  READLINE_POINT=${#PANEITY_PREFILL}
}
bind -x '"\C-x\C-p": __paneity_prefill_now'

# Signal readiness exactly once so the launcher knows when to send the trigger key.
__paneity_signal_ready() {
  if [ -z "$_paneity_ready_sent" ]; then
    : > "$PANEITY_READY"
    _paneity_ready_sent=1
  fi
}
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }__paneity_signal_ready"
```

Sourcing order matters in both directions:

- User init **first** so aliases and completions are present.
- Paneity overrides **after** so anything the user binds to Enter or sets as `HISTFILE` gets stomped.

`bind -x` runs the function inside the current shell, so `exit 0` terminates bash before any other Enter handler can fire. No DEBUG trap needed; the command line cannot reach bash's parser.

### Capture-file contract (shell-agnostic)

This is what the core treats as the boundary; any future adapter must honour it.

| State                              | Meaning   |
|------------------------------------|-----------|
| File missing                       | cancelled |
| File present, empty (or only `\n`) | cancelled |
| File present, single line of text  | run that line |

The adapter strips the trailing newline before invoking `cb`. The adapter is also responsible for cleaning up its own capture file in the on-exit callback, regardless of outcome.

### Prefill delivery

`PROMPT_COMMAND` runs before readline reads input, so once the ready file appears, readline is active and the trigger keystroke (`C-x C-p`) sent to `<session>:0.0` lands inside the `bind -x` handler. The handler sets `READLINE_LINE` from the env var and `READLINE_POINT` to end-of-line.

Prefill rides via env var, not via the wire, so shell metacharacters in the prefill cannot be misinterpreted.

If `$PANEITY_PREFILL` is empty, the launcher skips the polling/send-keys step entirely.

### Failure paths

- Detached session creation fails → adapter logs, calls `cb(nil)`.
- Popup display fails after session creation → kill the orphan session, call `cb(nil)`.
- Bash crashes / segfaults / is killed externally → capture file absent → `cb(nil)`.
- nvim itself dies between session-create and popup-close → orphan `paneity-popup-*` session persists until tmux server restart. Documented as a known v1 limitation.

## Core changes

### `M.new_command(opts)`

Externally the function name and call sites are unchanged. The opts table changes:

```lua
opts = {
  prefill   = string | nil,    -- nil → compute default; "" → explicitly no prefill
  post_exec = function | nil,  -- unchanged; called with the captured command
}
```

`opts.prompt` is dropped. The popup uses bash's own `PS1`; there is no caller-visible prompt label.

Default prefill resolution when `opts.prefill == nil`:

```lua
local function default_prefill()
  if vim.bo.buftype ~= "" then return "" end   -- terminal, help, etc.
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then return "" end
  return vim.fn.fnamemodify(name, ":.")        -- relative to nvim cwd
end
```

### Body

```lua
function M.new_command(opts)
  if not M.target_pane_id then
    return print_error("no target pane set.")
  end
  opts = vim.tbl_deep_extend("force", { post_exec = false }, opts or {})
  local prefill = opts.prefill ~= nil and opts.prefill or default_prefill()
  require("paneity.shells")[M.config.shell].get_command(prefill, function(command)
    if command and command ~= "" then
      M.run(command)
      if opts.post_exec then opts.post_exec(command) end
    end
  end)
end
```

`M.run`, `M.previous_command`, `M.last_paneity_command`, the termination ladder, `repeat_command`, marker, page-up/down, status-line — all unchanged.

### Config additions

```lua
M.defaults = {
  -- existing keys retained
  shell = "bash",
}
```

History storage:

```lua
local function default_histfile()
  local data = vim.env.XDG_DATA_HOME or (vim.env.HOME .. "/.local/share")
  return data .. "/paneity/history"
end
```

The bash adapter `mkdir -p`s the parent before launch. Not yet user-configurable.

## Breaking changes

- `opts.prompt` on `M.new_command` is removed. Any user-supplied keybinding passing `{ prompt = "..." }` will see the option silently ignored. README updated accordingly.
- The minimum supported tmux jumps to 3.2 (for `display-popup -E`). Older tmux loses the new-command feature with no graceful degradation.

## Integration tests

Per the project's testing policy the integration test defines the feature. New tests added to `tests/integration/`:

### Fixture: controlled bash environment

```
tests/integration/support/popup_home/
  .bashrc        # sets PANEITY_TEST_MARKER=1, defines `alias ptest='echo PTEST'`
```

Test harness points `HOME` at this fixture before launching nvim, so the popup's bash sources a known init.

### Test handle

Tests poll `require("paneity.shells.bash")._active_session` (cleared after popup close) to discover the popup-session target without scraping `tmux list-sessions`.

### Headline tests

1. **Default prefill end-to-end** — open a buffer with a known file path, trigger `M.new_command()`, wait for `_active_session`, `tmux capture-pane -t <session>:0.0 -p` and assert the prefill is visible at the prompt; `send-keys` `" && echo done" Enter`; assert target pane received `<file> && echo done`.
2. **Cancel via Ctrl-C** — trigger `M.new_command()`, wait for session, `send-keys C-c`, assert the session disappears, target pane is untouched, `previous_command` unchanged.
3. **User init really sourced** — with `HOME` pointed at the fixture, trigger `M.new_command()`, `send-keys "echo $PANEITY_TEST_MARKER" Enter`, assert target pane received `echo 1`.
4. **`opts.prefill = ""` overrides default** — call `M.new_command({ prefill = "" })`, capture popup pane, assert empty at the prompt.

### Explicitly out of scope for integration tests

- Bash's filename completion correctness — that's bash's job, not paneity's.
- Programmable completion (`git`, `kubectl`) — same reason; we only verify the rcfile is sourced.

## Non-goals (v1)

- Multiline commands. Single-line input only.
- Non-bash shells (`zsh`, `fish`). Strategy interface is ready; only `shells/bash.lua` is implemented. No `$SHELL` autodetect.
- Per-cwd or per-target history.
- Configurable history file path.
- `PANEITY_RCFILE_EXTRA` user-extension hook.
- Sending Ctrl-C to the target pane on popup cancel.
- Fallback when tmux/popup unavailable (paneity already requires tmux).
- Smarter prefill modes (visual selection, last command, word under cursor). `opts.prefill` exists for users who want to wire their own.
- Cleanup of orphan `paneity-popup-*` sessions from prior nvim crashes.
- Bash version detection. Assume `bind -x`, `$READLINE_LINE`, `PROMPT_COMMAND` — all present since bash 4.0.
