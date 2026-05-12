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

## How the previous process is terminated

When you re-run a command, Paneity tries to stop whatever's still running in the
target pane first. It does this **using only `tmux send-keys`** — no external
`kill`. That matters when your pane is running something like
`docker run/exec -it ...` or `ssh somewhere`: the keystrokes get forwarded
through the PTY *into* the container or remote session, so the inner command is
interrupted without killing the surrounding `docker`/`ssh` process and tearing
down your session.

The flow:

1. Read the pane's foreground command (`tmux display -p '#{pane_current_command}'`).
2. If it's already a shell (`bash`, `zsh`, `fish`, `sh`, `dash`), do nothing.
3. Otherwise send a first key:
   - **`C-d`** if it's a known REPL (`irb`, `pry`, `ipython`, `bpython`) —
     these exit cleanly on EOF and ignore `C-c`.
   - **`C-c`** otherwise.
4. Wait up to ~200ms for the foreground to drop back to a shell.
5. If it hasn't, escalate: a second `C-c`, then `C-\` (SIGQUIT). Each step
   has its own short wait.

The polling uses `vim.wait`, so Neovim stays responsive while it's happening.

### Caveats

* A process that ignores both SIGINT and SIGQUIT will survive, and your new
  command will queue up behind it. This is rare — most CLIs respect at least
  one of the two — but it can happen with poorly behaved native binaries or
  with PTYs that swallow signals.
* If you're inside a REPL whose name isn't in the list above (e.g. a top-level
  `python` or `node`), Paneity will send `C-c`, which most REPLs treat as
  "cancel current input line" rather than "exit". You'll need to exit the
  REPL yourself before paneity can run a new shell command in that pane.

## Never Asked Questions

Does Paneity ever close the pane?
> No. Close it yourself. Or don't.
