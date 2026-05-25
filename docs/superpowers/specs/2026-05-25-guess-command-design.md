# `guess_command`: filetype-aware prefill for the new-command popup

## Summary

Today `M.new_command()` prefills the popup with the active buffer's relpath. This
spec replaces that single-purpose default with a per-filetype guess pipeline:
each filetype can supply a function that returns a smarter prefill (e.g.
`bundle exec rspec spec/foo_spec.rb` for a Ruby spec). A `default` catch-all
preserves and extends today's behavior.

The feature is opt-in by virtue of overriding `guess_command` in `setup()`, and
extensible: users add new filetypes or replace shipped defaults with a single
table entry.

## Public API

### Config

`M.defaults.guess_command` is a new top-level config table:

```lua
guess_command = {
  default = function(ctx)
    if ctx.has_file("Makefile") then return "make" end
    return ctx.relpath
  end,

  lua  = function(ctx) ... end,
  ruby = function(ctx) ... end,
  rust = function(ctx) ... end,
}
```

User config merges via the existing `vim.tbl_deep_extend("force", ...)` path.
Providing `guess_command.ruby` in user config fully replaces the shipped
`ruby` handler. Setting an entry to `false` disables it (handler not called for
that filetype — falls straight to `default`).

### `ctx` table

Built once per `new_command` call, passed to whichever handler runs:

```lua
ctx = {
  filetype = "ruby",                       -- vim.bo.filetype
  bufname  = "/repo/spec/foo_spec.rb",     -- vim.api.nvim_buf_get_name(0)
  relpath  = "spec/foo_spec.rb",           -- fnamemodify(bufname, ":.")
  basename = "foo_spec.rb",                -- fnamemodify(bufname, ":t")
  cwd      = "/repo",                      -- vim.fn.getcwd()

  has_file      = function(name) ... end,  -- exists at cwd
  find_ancestor = function(name) ... end,  -- walk parents from bufdir; nil or path
  contents      = function() ... end,      -- whole buffer as a string;
                                           -- lazy + memoized on this ctx
}
```

Helper semantics:

- `has_file(name)` — `vim.fn.filereadable(cwd .. "/" .. name) == 1`. Single check
  against nvim's cwd. Used when the downstream tool (e.g. `make`) runs in cwd.
- `find_ancestor(name)` — walk from the buffer's directory toward `/`,
  returning the first absolute path where `name` exists, else `nil`. Used when
  the downstream tool (e.g. `cargo`, `bundle`) walks up itself, so detecting an
  ancestor marker is the right signal.
- `contents()` — `table.concat(nvim_buf_get_lines(bufnr, 0, -1, false), "\n")`,
  computed on first call and cached on the ctx instance. Lazy because most
  handlers never look at file contents; memoized because a handler that does
  inspect contents may do so repeatedly.

### Resolution flow

The existing `default_prefill` function grows to build `ctx` and run the
pipeline. Its signature and call site are unchanged.

1. If `vim.bo.buftype ~= ""` → return `""`. (Unchanged from today.)
2. If `bufname == ""` → return `""`. (Unchanged.)
3. Build `ctx`.
4. Let `handler = M.config.guess_command[ctx.filetype]`.
5. If `handler` is a function, call `handler(ctx)`. If it returns a non-nil
   string, that's the prefill — return it. Any non-function value (including
   `false` or `nil`) skips this step.
6. Otherwise call `M.config.guess_command.default(ctx)` (assumed to be a
   function — the shipped default is, and replacing it with a non-function
   is user error).
7. If that returns `nil` → return `""`.

### Exposed defaults

```lua
require("paneity").defaults.guess_command.ruby   -- the shipped function
require("paneity").defaults.guess_command.default
```

Users can call these from inside an override to compose:

```lua
ruby = function(ctx)
  if ctx.relpath:match("^acceptance/") then
    return "cucumber " .. ctx.relpath
  end
  return paneity.defaults.guess_command.ruby(ctx)
end,
```

### Public surface unchanged

No new public functions. `M.new_command({ prefill = nil })` continues to be the
single entry point. `prefill = ""` still suppresses; a literal string still wins
over the guess pipeline.

## Shipped defaults

Deliberately small. Each default is an opinion paneity has to maintain as
ecosystems shift, and the API itself is the feature.

```lua
ruby = function(ctx)
  if ctx.relpath:match("_spec%.rb$") or ctx.relpath:match("/spec/") then
    return "bundle exec rspec " .. ctx.relpath
  end
  if ctx.relpath:match("_test%.rb$") or ctx.relpath:match("/test/") then
    return "bundle exec rake test TEST=" .. ctx.relpath
  end
  return "ruby " .. ctx.relpath
end,

rust = function(ctx)
  if ctx.find_ancestor("Cargo.toml") then return "cargo test" end
end,

lua = function(ctx)
  if ctx.relpath:match("_spec%.lua$") and ctx.has_file("Makefile") then
    return "make test"
  end
end,

default = function(ctx)
  if ctx.has_file("Makefile") then return "make" end
  return ctx.relpath
end,
```

Notable omissions:

- **Python, Go, JavaScript/TypeScript**: too fragmented (pytest/unittest/nose,
  jest/vitest/mocha/bun, monorepos). A bad default is worse than none. Users
  add their own via the same API.
- **C**: the only useful generic heuristic is "Makefile → make", which the
  `default` handler already covers. No separate handler shipped.

## File layout

- `lua/paneity/init.lua` — resolution logic. The existing `default_prefill`
  function grows to build `ctx` and call the resolver. A new internal seam
  `M._resolve_prefill(ctx, guess_command_config)` carries the pure resolution
  logic so unit tests can exercise it without touching real buffers.
- `lua/paneity/guess_command.lua` — **new file**, returns a table of the shipped
  default handlers. Pure data + functions; no side effects on require. This
  keeps the regexes out of `init.lua` but adds no new abstractions.
- `lua/paneity/init.lua` exposes `M.defaults.guess_command = require("paneity.guess_command")`.

`lua/paneity/utils.lua` remains unrelated and untouched (dead code, per CLAUDE.md).

## Testing

### Unit tests — `tests/unit/guess_command_spec.lua`

Direct calls into `M._resolve_prefill(ctx, config)` with synthesized ctx tables.
No tmux, no real buffers. Cases:

- filetype handler returns string → wins over `default`
- filetype handler returns `nil` → falls through to `default`
- no handler for filetype → `default` runs
- `default` returning `nil` → resolver returns `""`
- user override fully replaces shipped default
- shipped defaults: each branch of `ruby` (`_spec.rb`, `_test.rb`, fallthrough),
  `rust` (Cargo.toml found vs not), `lua` (spec + Makefile vs not), `default`
  (Makefile vs no Makefile)
- helper behavior against a tempdir:
  - `has_file` true/false
  - `find_ancestor` finds at root, finds mid-walk, returns nil at filesystem root
  - `contents` lazy (not invoked unless handler calls it), memoized (single
    underlying read), returns expected string

### Integration test — `tests/integration/guess_command_spec.lua`

Per CLAUDE.md, every feature gets an integration test that mirrors the user
experience. One end-to-end case is enough — the filetype matrix is unit-test
territory.

Flow:

1. Spin up the isolated tmux server (existing `TMUX_TMPDIR` pattern).
2. Open nvim in that server. Set cwd to a tempdir, create `spec/foo_spec.rb`.
3. `require("paneity").setup()` with shipped defaults.
4. Set a target pane.
5. Open the spec file in nvim. Trigger `M.new_command()`.
6. Poll the popup (existing test helpers) and assert its command-line content
   contains `bundle exec rspec spec/foo_spec.rb`.

## Behavior preserved

- `prefill = ""` explicit suppression: unchanged.
- `prefill = "literal"`: unchanged — bypasses the guess pipeline.
- Non-file buffers (`buftype ~= ""`): unchanged — short-circuit to `""`.
- Empty bufname: unchanged — short-circuit to `""`.
- Default behavior for users who never configure `guess_command` and aren't in
  a Makefile project: still `relpath`. Inside a Makefile project, prefill now
  defaults to `make` instead of relpath — minor behavior change, documented in
  README.

## Documentation

New section in `README.md` after **Setting a new command (`<leader>tc`)**:

- `guess_command` config block with example.
- `ctx` table contents and helper semantics.
- Override and compose patterns (calling into `paneity.defaults.guess_command.<ft>`).
- Disabling a shipped default (`ruby = false`).
- The shipped default list (lua, ruby, rust, default).
