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

* Attach to an existing pane (choose from menu)
* Open a new pane (set same current directory)
* Set an arbitrary command to run
* Re-run the command with a leader keybinding
* Abort partial/failed tests and builds by sending `ctrl-c`
* Scroll the attached pane up and down without leaving Neovim
* Configure how your splits are created or leave tmux defaults in place
* Add a marker to indicate the currently attached tmux pane

## Installation

### Using lazy.nvim
```lua
{
  "bestie/paneity",
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

## Never Asked Questions

Does Paneity ever close the pane?
> No. Close it yourself. Or don't.
