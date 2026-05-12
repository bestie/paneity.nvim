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
* Set an arbitrary command to run
* Re-run the command with a keybinding (default <leader><leader>)
* Terminates the previously started process if it's still running
* Can scroll the attached pane up and down without leaving Neovim (default <PageUp>/<PageDown>)
* Configurable tmux splitting
* Adds a marker to the tmux border of the selected pane (configuratble marker)
* Easy status line function that can be added [lualine](https://github.com/nvim-lualine/lualine.nvim) etc.
* Configurable key bindings

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

### `termination (table)`

Controls how Paneity clears the target pane before running a new command.

```lua
require("paneity").setup({
  termination = {
    -- Send-keys ladder. The first entry is always sent (harmless at an idle
    -- prompt). Subsequent entries are sent only if Paneity issued the
    -- previous command in this pane.
    key_sequence    = { "C-c", "C-\\" },

    -- After the key_sequence is exhausted, send `kill -TERM` to the
    -- foreground process group. Doubly gated: requires Paneity ownership AND
    -- the new command must match the previous one (you are re-running the same
    -- thing). Disable if you run docker-style wrappers where SIGTERM kills the
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

1. If the shell is already in the foreground, do nothing.
2. Send the first key in `termination.key_sequence` (`C-c` by default). This is
   harmless at an idle prompt and clears any partial command line or interrupts a
   running process. Wait up to `step_timeout_ms` for the shell to return.
3. If the foreground still isn't the shell — and Paneity issued the current
   command — send subsequent keys in the sequence (`C-\\` by default). Each step
   has its own `step_timeout_ms` wait.
4. If the sequence is exhausted and `send_term = true` — and you are re-running
   the exact same command — send `kill -TERM` to the foreground process group.
5. If all else fails, Paneity prompts: **Type anyway**, **Cancel**, or
   **kill -TERM**.

Steps 3–4 are gated on Paneity ownership (the command was started by Paneity, not
typed by hand). Step 4 is additionally gated on the new command matching the
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
* Disable `send_term` if you run docker-style wrappers where `SIGTERM` kills the
  host-side CLI but leaves the container process orphaned.

## Never Asked Questions

Does Paneity ever close the pane?
> No. Close it yourself. Or don't.
