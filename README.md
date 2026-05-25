# Paneity 🥖

(_noun_) the quality or state of being bread

---

**Paneity** is a [Neovim](https://github.com/neovim/neovim) plugin for running
commands in another [tmux](https://github.com/tmux/tmux) pane without leaving
your editor.

It's optimized for running tests, builds or other repetative tasks while keeping a
persistent session open and visible.

Paneity allows you to attach to an existing pane or open a new one.

---

## Features

* Attach to an existing pane (choose with native UI or fzf-lua)
* Open a new pane (set same current directory)
* Set an arbitrary command to run via a real shell popup (see below)
* Re-run the command with a keybinding (default <leader><leader>)
* Attempts to quit running processes with ctrl-c (configuratble)
* Can scroll the attached pane up and down without leaving Neovim (default <PageUp>/<PageDown>)
* Configurable tmux splitting
* Adds a marker to the tmux border of the selected pane (configuratble marker)
* Easy status line function that can be added [lualine](https://github.com/nvim-lualine/lualine.nvim) etc.
* Configurable key bindings

## Setting a new command (`<leader>tc`)

Pressing `<leader>tc` opens a popup running a real bash shell. Type your command with full filename and bash completion, alias expansion, and history — just like in any other terminal. Press Enter to send the command to the target pane; Ctrl-C cancels with no effect on the target.

The popup sources your normal shell init (`~/.bashrc`, etc.) so aliases and completions work exactly as in your day-to-day shell. Paneity overrides the popup's `HISTFILE` so its history is a separate, paneity-only file (under `$XDG_DATA_HOME/paneity/history` or `~/.local/share/paneity/history`).

### `M.new_command(opts)`

`M.new_command(opts)` accepts:

- `prefill` (`string | nil`) — initial content of the popup's command line.
  `nil` (the default) uses the active buffer's file path relative to nvim's cwd, or
  an empty string for non-file buffers. Pass `""` to explicitly suppress the default.
- `post_exec` (`function | nil`) — called with the captured command string after `M.run` returns.

`opts.prompt` was removed in this release; the popup shows the user's own bash prompt (`PS1`) instead of a configurable label.

## Guessing the command (`guess_command`)

Paneity tries to prefill the popup with something useful based on the active
buffer's filetype. The shipped defaults cover a small set of common cases:

| Filetype | Behavior                                                              |
| -------- | --------------------------------------------------------------------- |
| `ruby`   | `bundle exec rspec <path>` for `*_spec.rb` or files under `/spec/`; `bundle exec rake test TEST=<path>` for `*_test.rb` or files under `/test/`; otherwise `ruby <path>` |
| `rust`   | `cargo test` when `Cargo.toml` is found in any ancestor directory     |
| `lua`    | `make test` when editing `*_spec.lua` and a `Makefile` exists at cwd  |
| _other_  | The `default` handler: `make` if a `Makefile` exists at cwd; otherwise the file's path relative to nvim's cwd |

Override any of these — or add a handler for a filetype paneity doesn't ship:

```lua
require("paneity").setup({
  guess_command = {
    -- Custom handler for python
    python = function(ctx)
      if ctx.basename:match("^test_") then
        return "pytest " .. ctx.relpath
      end
      return "python " .. ctx.relpath
    end,

    -- Disable the shipped ruby handler entirely
    ruby = false,

    -- Compose with the shipped default
    rust = function(ctx)
      if ctx.has_file("justfile") then return "just test" end
      return require("paneity").defaults.guess_command.rust(ctx)
    end,
  },
})
```

### The `ctx` table

Each handler receives a `ctx` table:

```lua
ctx = {
  filetype = "ruby",                       -- vim.bo.filetype
  bufname  = "/repo/spec/foo_spec.rb",     -- absolute path
  relpath  = "spec/foo_spec.rb",           -- relative to nvim's cwd
  basename = "foo_spec.rb",
  cwd      = "/repo",

  has_file      = function(name) ... end,  -- true if <cwd>/<name> exists
  find_ancestor = function(name) ... end,  -- walk parents from buf dir;
                                           -- returns absolute path or nil
  contents      = function()     ... end,  -- whole buffer as string;
                                           -- lazy, memoized
}
```

`has_file` vs `find_ancestor`: use `has_file` when the downstream tool runs in
cwd (like `make`). Use `find_ancestor` when the downstream tool walks up itself
(like `cargo` or `bundle`) — finding a marker anywhere upstream means the
tool will find its own root.

### Resolution order

1. Non-file buffers (`buftype ~= ""`) and unnamed buffers → no prefill.
2. Otherwise the resolver looks up `guess_command[<filetype>]`. If it's a
   function returning a string, that's the prefill.
3. Otherwise `guess_command.default(ctx)` runs.
4. If `default` returns nil, the prefill is empty.

A handler set to `false` is treated as "disabled" — the resolver skips it and
falls straight to `default`.

## Requirements

- [Neovim](https://github.com/neovim/neovim) 0.8+
- tmux **3.2 or newer** is required (uses `display-popup -E` for the new-command popup).

## Installation

### Using lazy.nvim
```lua
{
  "bestie/paneity.nvim",
  config = function()
    require("paneity").setup()
  end,
}
```

## Configuration

The following is the default configuration that you will get if you call `setup()` with no argument.

```lua
require("paneity").setup({
  marker = "🥖🕹️", -- The marker string to indicate the attached pane
  split_direction = nil, -- Options: "horizontal", "vertical" (nil means tmux default)
  split_size = nil, -- Number rows/columns of available space (nil means tmux default)
  split_percentage_size = nil, -- Percentage of available space, takes precendence over `split_size` (nil means tmux default)
  log_level = vim.log.levels.OFF,
  shell = "bash", -- Shell adapter for the new-command popup. Only "bash" is supported in this release.
  termination = { -- See `termination` section below for details
    key_sequence    = { "C-c", "C-\\" },
    send_term       = true,
    step_timeout_ms = 200,
  },
  keybindings = { -- false to disable all keybindings
    -- set individual keybindings to false to disable
    toggle = "<leader>tp", -- Toggle on/off, on sets target pane or opens a new one
    new_command = "<leader>tc", -- Set a new command and run it in the pane
    repeat_command = "<leader><leader>", -- Re-run the last command
    page_up = "<PageUp>", -- Scroll the pane up
    page_down = "<PageDown>", -- Scroll the pane down
    up_enter = "<leader><Up>", -- Re-run via ↑ ENTER
  }
})
```

### `marker (string)`

A decorative string which is added to the top of the tmux pane's border.

You may set it to `""` or anything else you like `"(❀◦‿◦)"`

### `split_direction (string or nil)`

Direction of the new tmux split:
* "horizontal": Side-by-side panes (tmux split-window -h).
* "vertical": Stacked panes (tmux split-window -v).
* nil: Default tmux behavior.

Note: `tmux split-window -h` creates two side-by-side panes, don't be mad at me.

### `split_size (number or nil)`

Fixed size for new tmux splits (rows or columns).
Ignored if `split_percentage_size` is set.

### `split_percentage_size (number or nil)`

Proportionally size for new splits as a percentage of available rows or columns.
Takes precendence over `split_size`.

### `keybindings table {} or false`

See default configuration for valid command names.

Any provided values are merged with the defaults.

Set to `false` to disable all keybindings.
```lua
require("paneity").setup({
  keybindings = false
})
```

To disable specific keybindings, set them to `false`.
```lua
require("paneity").setup({
  keybindings = {
    toggle = false, -- Don't bind toggle to anything
  }
})
```

### `shell (string)`

- `shell` (string, default `"bash"`) — which shell adapter to use for the new-command popup.
  Only `"bash"` is implemented in this release; the strategy interface is designed so other
  shells (`"zsh"`, `"fish"`) can be added without core changes.

### `termination (table)`

Controls how Paneity clears the target pane before running a new command.

```lua
require("paneity").setup({
  termination = {
    -- Send-keys ladder. The first entry is sent on every paneity command,
    -- even at an idle prompt — it clears any partial command left at the
    -- shell prompt. Subsequent entries are sent only if Paneity issued the
    -- command that is currently running in the pane.
    key_sequence    = { "C-c", "C-\\" },

    -- After the key_sequence is exhausted, send `kill -TERM` to the
    -- foreground process group. Doubly gated: requires Paneity ownership AND
    -- the new command must match the previous one (whitespace is normalized).
    -- Disable if you run docker-style wrappers where SIGTERM kills the
    -- host-side CLI but leaves the container process orphaned.
    send_term       = true,

    -- Time (ms) to wait after each escalation step for the shell to return.
    step_timeout_ms = 200,
  },
})
```

## How the previous process is terminated

When you re-run a command, Paneity tries to stop whatever's still running in the
target pane first. Detection is **PID-based** (not name-based): Paneity reads the
pane's tty foreground process group and compares it to the pane's shell PID, so
`bash my_script.sh` is correctly identified as "something is running" rather than
treated as an idle shell.

The escalation ladder:

1. Send the first key in `termination.key_sequence` (`C-c` by default). This
   happens unconditionally — it clears any partial command at an idle prompt,
   or interrupts a running process. Wait up to `step_timeout_ms` for the
   shell to return.
2. If the foreground still isn't the shell — and Paneity issued the command
   that's currently running in the pane — send subsequent keys in the
   sequence (`C-\\` by default). Each step has its own `step_timeout_ms` wait.
3. If the sequence is exhausted and `send_term = true` — and the new command
   matches the previous one (whitespace is normalized — `'make test'` and
   `'  make   test  '` are equivalent) — send `kill -TERM` to the foreground
   process group.
4. If all else fails, Paneity prompts: **Type anyway**, **Cancel**, or
   **kill -TERM**.

Steps 2–3 are gated on Paneity ownership (the command was started by Paneity, not
typed by hand). Step 3 is additionally gated on the new command matching the
previous one — replacing a command with a different one skips the TERM signal.

The polling uses `vim.wait`, so Neovim stays responsive while it's happening.

### Why send-keys rather than `kill`?

`tmux send-keys` forwards keystrokes through the PTY *into* whatever is running —
so `C-c` inside `docker run/exec -it ...` or `ssh somewhere` reaches the inner
process rather than killing the surrounding `docker`/`ssh` process. Only the
explicit `send_term` step sends a real signal, and it is opt-out rather than
opt-in.

### Caveats

* A process that ignores both SIGINT and SIGQUIT and `SIGTERM` will survive, and
  your new command will be typed into its stdin. Paneity prompts you in that case.
* See the `send_term` note above for docker-style wrapper caveats.
* **REPL users:** If your pane runs a REPL that exits on EOF (irb, pry,
  ipython), you may want to configure `key_sequence = { "C-d", "C-c" }` so
  Paneity exits the REPL cleanly before sending a new command. Previous
  versions of Paneity hard-coded this behaviour; it is now opt-in via config.
  Note: when you configure two keys, only the first is sent unconditionally;
  the second is gated on Paneity ownership. If your manually-launched REPL
  ignores the first key, Paneity will show the prompt rather than sending the
  second.

## Development

### Running the tests

You need `nvim` and `tmux` on your `PATH`. Then:

```bash
make test
```

`make test` runs the full suite (unit + integration) under headless
Neovim. Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s
`PlenaryBustedDirectory`; plenary is cloned on demand into `deps/plenary.nvim`
(gitignored). There is no separate build step or linter.

### Test layout

- **`tests/unit/`** — fast, no real tmux. Stubs the internal seams on `M`
  (the underscore-prefixed members listed below) and asserts on recorded
  calls. This is where most behavior tests live.
- **`tests/integration/`** — spins up a private tmux server per test via
  `vim.env.TMUX_TMPDIR = $(mktemp -d)`. Both the test's `vim.fn.system`
  calls and the plugin's `io.popen` calls inherit this env var, so all
  `tmux` invocations land on an isolated socket — your real tmux session is
  never touched. Cleanup runs `tmux kill-server` and removes the tmpdir.

### Code layout

Everything lives in `lua/paneity/init.lua`. The module table `M` holds
**both** the public API and persistent state (`M.target_pane_id`,
`M.previous_command`, `M.last_paneity_command`, `M.config`).

All tmux interaction goes through `shell_exec` (a thin `io.popen` wrapper).
There's no libuv, no `vim.system`, no job control. Calls are **synchronous
and blocking** on the Neovim main loop — keep them cheap.

`setup()` is deliberately re-entrant: it preserves existing state on reload
via the `M.target_pane_id = M.target_pane_id or nil` idiom. Don't refactor
this state into locals without preserving that property — users reload
configs and the plugin shouldn't lose track of its target pane.

### Internal seams

Functions whose names start with `M._` are stubbable in unit tests. They
thinly wrap an external call (tmux, ps, kill, `vim.fn.confirm`) and live
on the module table so tests can replace them. Production callers route
through them too. Current seams:

- `M._pane_pid(pane_id)` — wraps `tmux display -p '#{pane_pid}'`.
- `M._tty_foreground_pgid(pane_pid)` — wraps `ps -o tpgid= -p <pid>`.
- `M._send_keys(pane_id, key)` — wraps `tmux send-keys -t %s '%s'`.
  Always single-quotes the key, so call sites pass bare `"C-c"` / `"C-\\"`.
- `M._kill(pid, signal)` — wraps `kill -SIG <pid>`.
- `M._prompt_termination_choice()` — wraps `vim.fn.confirm` for the
  termination fallback prompt.
- `M._terminate_foreground(pane_id, new_command)` — the escalation ladder
  itself; promoted to the module so tests can drive it directly.

If you add a new external interaction, make it a seam — it keeps unit
tests fast and deterministic without needing a real tmux server.

### Test stub patterns

Unit tests use a small `queue()` helper that feeds successive return
values to a stubbed seam, sticking on the last value once exhausted. With
`step_timeout_ms = 5` and `vim.wait`'s default interval of 50ms, each
`wait_for_shell` invocation calls the predicate twice (immediate + at
timeout). Combined with the initial `shell_is_foreground` call at the top
of `_terminate_foreground` and the direct `_tty_foreground_pgid` call in
the TERM branch, queue lengths should be sized to cover the expected call
count for the path under test.

### Manual smoke testing

```
nvim                                     # under tmux
:lua require("paneity").setup()
```

Then exercise the keybindings against a real pane.

## Never Asked Questions

Does Paneity ever close the pane?
> No. Close it yourself. Or don't.
