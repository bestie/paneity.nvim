# TODO

Issues found during a code read of `lua/paneity/init.lua`. Not yet triaged.

## Bugs

### Broken config option: `split_percentage_size`
- **Where:** `lua/paneity/init.lua:111` reads `M.config.split_size_percentage`; `M.defaults` (`:367`) and the README declare `split_percentage_size`.
- **Effect:** The documented option silently does nothing. Only the typo'd key works.
- **Fix:** Pick one name (the documented `split_percentage_size`), use it in both places.

### Single-quote injection in `send-keys`
- **Where:** `send_command` at `lua/paneity/init.lua:33` — `tmux send-keys -t %s '%s' C-m`.
- **Effect:** Any command containing a `'` (e.g. `echo 'hi'`) breaks out of the quoting; tmux receives mangled input.
- **Fix:** Escape single quotes (`'\''`) or pass the command via a different mechanism (e.g. write to a temp file, or use `tmux send-keys` literal mode).

### `inputlist` cancel selects the first item
- **Where:** `native_selection_ui` at `lua/paneity/init.lua:170-172`.
- **Effect:** Pressing Enter (cancel) at the prompt returns `0`, which maps to `menu_items[2]` — the first real entry. No bounds/cancel check.
- **Fix:** Treat `selection == 0` or out-of-range as cancel; bail out without calling `on_selection`.

### `prompt` leaks to global scope
- **Where:** `lua/paneity/init.lua:224` — `prompt = "Select a target pane > "` (missing `local`).
- **Effect:** Pollutes the global namespace.
- **Fix:** Add `local`.

## Robustness

### Stale target pane after external close
- If the user closes the target pane in tmux, `M.target_pane_id` stays set and subsequent `run` / `repeat_command` silently no-op.
- **Fix:** Before sending, verify the pane still exists (`tmux list-panes -F '#{pane_id}'` or `tmux display -t <id>`); if not, clear state and prompt to re-select.

### Fragile pane-list parsing
- `pane_list_format` at `lua/paneity/init.lua:36` uses `:` as delimiter; parsed with `([^:]*):([^:]*):([^:]*):([^:]*)` at `:43`.
- A `pane_current_command` containing `:` mis-splits the row.
- **Fix:** Use an unlikely delimiter (e.g. `\t` or a multi-char sentinel), or put `pane_current_command` last and use a non-greedy split.

## Dead code / cleanup

### Unused `lua/paneity/utils.lua`
- Not required anywhere. Has divergent conventions (relative log path, `vim.g.paneity_debug`) that don't match `init.lua`.
- **Fix:** Delete, or fold its `send_command` (which uses `C-a C-k` to clear the line — arguably nicer than `C-c`) back into `init.lua` if that behavior is wanted.

### Leftover rename artifacts in `plugin/paneity.lua`
- Hard-codes `vim.g.paneity_debug = true` (`:5`) — overrides any user setting and only affects the dead `utils.lua` anyway.
- Registers `:TmuxPaneControl` (`:9`) — leftover from the pre-rename name.
- **Fix:** Drop the `paneity_debug` line; rename the user command to `:Paneity` (or remove it — `require("paneity").setup()` from a user's lazy spec is the documented entry).
