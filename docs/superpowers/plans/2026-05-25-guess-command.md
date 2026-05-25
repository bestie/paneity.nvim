# guess_command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `default_prefill`'s single-purpose relpath fallback with a per-filetype guess pipeline that ships defaults for lua, ruby, rust, and a Makefile-aware catch-all.

**Architecture:** A pure resolver (`M._resolve_prefill`) consumes a ctx table built by `M._build_ctx`. The ctx exposes paths plus three helpers (`has_file`, `find_ancestor`, `contents`). User config under `guess_command` deep-merges over shipped defaults from `lua/paneity/guess_command.lua`. The existing `default_prefill` local function calls the two seams; the public `new_command(opts)` entry point is unchanged.

**Tech Stack:** Lua 5.1 (Neovim's LuaJIT), plenary.nvim's busted runner, tmux. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-05-25-guess-command-design.md`.

---

## File Structure

**Create:**
- `lua/paneity/guess_command.lua` — table of shipped default handlers (`default`, `lua`, `ruby`, `rust`). Pure data + functions, no side effects on require.
- `tests/unit/guess_command_spec.lua` — unit tests for the resolver, the ctx builder, and the shipped defaults.
- `tests/integration/guess_command_spec.lua` — single end-to-end case proving the popup gets the guessed prefill.

**Modify:**
- `lua/paneity/init.lua` — add `M._resolve_prefill` and `M._build_ctx` seams, rewire `default_prefill`, extend `M.defaults` with `guess_command`.
- `README.md` — new section after "Setting a new command" documenting the API.

---

## Task 1: Pure resolver seam — `M._resolve_prefill`

The resolver is pure: it takes a synthesized ctx table and a `guess_command` config table, returns the resolved prefill string. Doing this first means later tasks can build on a tested resolver.

**Files:**
- Create: `tests/unit/guess_command_spec.lua`
- Modify: `lua/paneity/init.lua` (add `M._resolve_prefill` near other `M._` seams, around line 86)

- [ ] **Step 1: Write the failing tests**

Create `tests/unit/guess_command_spec.lua`:

```lua
-- Unit tests for the guess_command pipeline.
--
-- Resolver tests pass synthesized ctx tables directly to
-- M._resolve_prefill, so no real buffer or filesystem is required.

describe("guess_command (unit)", function()
  local paneity

  before_each(function()
    package.loaded["paneity"] = nil
    paneity = require("paneity")
    paneity.setup({ keybindings = false })
  end)

  describe("_resolve_prefill", function()
    local function ctx(overrides)
      local base = {
        filetype = "ruby",
        bufname  = "/repo/spec/foo_spec.rb",
        relpath  = "spec/foo_spec.rb",
        basename = "foo_spec.rb",
        cwd      = "/repo",
        has_file      = function() return false end,
        find_ancestor = function() return nil end,
        contents      = function() return "" end,
      }
      for k, v in pairs(overrides or {}) do base[k] = v end
      return base
    end

    it("returns the filetype handler's result when it is a non-empty string", function()
      local config = {
        ruby    = function() return "bundle exec rspec spec/foo_spec.rb" end,
        default = function() return "FALLBACK" end,
      }
      assert.are.equal(
        "bundle exec rspec spec/foo_spec.rb",
        paneity._resolve_prefill(ctx(), config))
    end)

    it("falls through to default when the filetype handler returns nil", function()
      local config = {
        ruby    = function() return nil end,
        default = function() return "FALLBACK" end,
      }
      assert.are.equal("FALLBACK", paneity._resolve_prefill(ctx(), config))
    end)

    it("calls default when there is no handler for the filetype", function()
      local config = {
        default = function() return "FALLBACK" end,
      }
      assert.are.equal(
        "FALLBACK",
        paneity._resolve_prefill(ctx({ filetype = "klingon" }), config))
    end)

    it("returns empty string when default returns nil", function()
      local config = {
        default = function() return nil end,
      }
      assert.are.equal("", paneity._resolve_prefill(ctx({ filetype = "klingon" }), config))
    end)

    it("treats a false handler as disabled and falls through to default", function()
      local config = {
        ruby    = false,
        default = function() return "FALLBACK" end,
      }
      assert.are.equal("FALLBACK", paneity._resolve_prefill(ctx(), config))
    end)

    it("passes ctx through to handlers", function()
      local seen
      local config = {
        ruby    = function(c) seen = c; return c.relpath end,
        default = function() return "" end,
      }
      paneity._resolve_prefill(ctx({ relpath = "x/y.rb" }), config)
      assert.are.equal("x/y.rb", seen.relpath)
    end)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: failures in `tests/unit/guess_command_spec.lua` complaining that `paneity._resolve_prefill` is nil / not callable.

- [ ] **Step 3: Implement the resolver**

Add to `lua/paneity/init.lua` immediately after `M._prompt_termination_choice` (around line 96):

```lua
-- Pure resolver for the guess_command pipeline. Takes a ctx table and a
-- guess_command config table, returns the resolved prefill (string).
-- Falls back to "" only if neither the filetype handler nor `default`
-- produces a non-nil string.
function M._resolve_prefill(ctx, guess_command)
  local handler = guess_command[ctx.filetype]
  if type(handler) == "function" then
    local result = handler(ctx)
    if type(result) == "string" then return result end
  end
  local default = guess_command.default
  if type(default) == "function" then
    local result = default(ctx)
    if type(result) == "string" then return result end
  end
  return ""
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: all tests in `tests/unit/guess_command_spec.lua` pass; other tests still pass.

- [ ] **Step 5: Commit**

```bash
git add lua/paneity/init.lua tests/unit/guess_command_spec.lua
git commit -m "Add guess_command pipeline resolver"
```

---

## Task 2: ctx builder skeleton — paths only

Build the ctx table for the current buffer, exposing the five path-derived fields. Helpers come in subsequent tasks; we'll stub them with no-ops so the table shape stays stable.

**Files:**
- Modify: `lua/paneity/init.lua` (new `M._build_ctx` near other `M._` seams)
- Modify: `tests/unit/guess_command_spec.lua` (new `describe` block)

- [ ] **Step 1: Write the failing test**

Append to `tests/unit/guess_command_spec.lua` inside the top-level `describe`:

```lua
  describe("_build_ctx", function()
    local buf, prev_cwd

    before_each(function()
      prev_cwd = vim.fn.getcwd()
      local tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir .. "/spec", "p")
      vim.cmd("cd " .. vim.fn.fnameescape(tmpdir))

      buf = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(buf, tmpdir .. "/spec/foo_spec.rb")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "describe 'foo' do", "end" })
      vim.bo[buf].filetype = "ruby"
      vim.api.nvim_set_current_buf(buf)
    end)

    after_each(function()
      vim.cmd("cd " .. vim.fn.fnameescape(prev_cwd))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("populates filetype, bufname, relpath, basename, cwd", function()
      local ctx = paneity._build_ctx(buf)
      assert.are.equal("ruby", ctx.filetype)
      assert.are.equal(vim.fn.getcwd() .. "/spec/foo_spec.rb", ctx.bufname)
      assert.are.equal("spec/foo_spec.rb", ctx.relpath)
      assert.are.equal("foo_spec.rb", ctx.basename)
      assert.are.equal(vim.fn.getcwd(), ctx.cwd)
    end)
  end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: failure — `paneity._build_ctx` is nil.

- [ ] **Step 3: Implement the ctx builder**

Add to `lua/paneity/init.lua` immediately after `M._resolve_prefill`:

```lua
-- Builds the ctx table consumed by guess_command handlers. `bufnr` is
-- the buffer to inspect; defaults to the current buffer when nil/0.
-- Helpers (has_file, find_ancestor, contents) come on the table; they
-- are stubbed here and filled in by subsequent tasks.
function M._build_ctx(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local cwd = vim.fn.getcwd()
  return {
    filetype = vim.bo[bufnr].filetype,
    bufname  = bufname,
    relpath  = vim.fn.fnamemodify(bufname, ":."),
    basename = vim.fn.fnamemodify(bufname, ":t"),
    cwd      = cwd,
    has_file      = function(_) return false end,
    find_ancestor = function(_) return nil end,
    contents      = function() return "" end,
  }
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: new test passes; nothing else regresses.

- [ ] **Step 5: Commit**

```bash
git add lua/paneity/init.lua tests/unit/guess_command_spec.lua
git commit -m "Add ctx builder skeleton for guess_command"
```

---

## Task 3: `ctx.has_file` helper

Real implementation: returns true when `<cwd>/<name>` exists and is readable. Single check, no walking.

**Files:**
- Modify: `lua/paneity/init.lua` (replace stubbed `has_file` in `_build_ctx`)
- Modify: `tests/unit/guess_command_spec.lua`

- [ ] **Step 1: Write the failing test**

Append inside the `_build_ctx` describe block:

```lua
    it("has_file returns true for files at cwd", function()
      vim.fn.writefile({ "" }, vim.fn.getcwd() .. "/Makefile")
      local ctx = paneity._build_ctx(buf)
      assert.is_true(ctx.has_file("Makefile"))
    end)

    it("has_file returns false when the file is absent", function()
      local ctx = paneity._build_ctx(buf)
      assert.is_false(ctx.has_file("DoesNotExist"))
    end)

    it("has_file checks cwd only, not ancestors", function()
      -- Makefile lives at cwd; cd into a subdir so cwd shifts away.
      vim.fn.writefile({ "" }, vim.fn.getcwd() .. "/Makefile")
      vim.cmd("cd spec")
      local ctx = paneity._build_ctx(buf)
      assert.is_false(ctx.has_file("Makefile"))
    end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: three new failures — the stub always returns false, but the first test expects true.

- [ ] **Step 3: Replace the stub**

In `M._build_ctx`, change the `has_file` line to:

```lua
    has_file = function(name)
      return vim.fn.filereadable(cwd .. "/" .. name) == 1
    end,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: all three tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/paneity/init.lua tests/unit/guess_command_spec.lua
git commit -m "Implement ctx.has_file in guess_command builder"
```

---

## Task 4: `ctx.find_ancestor` helper

Walk from the buffer's directory toward `/`, return the first absolute path where `name` exists, or `nil`.

**Files:**
- Modify: `lua/paneity/init.lua` (replace stubbed `find_ancestor`)
- Modify: `tests/unit/guess_command_spec.lua`

- [ ] **Step 1: Write the failing tests**

Append inside the `_build_ctx` describe block:

```lua
    it("find_ancestor returns absolute path when marker is at cwd", function()
      local cwd = vim.fn.getcwd()
      vim.fn.writefile({ "" }, cwd .. "/Cargo.toml")
      local ctx = paneity._build_ctx(buf)
      assert.are.equal(cwd .. "/Cargo.toml", ctx.find_ancestor("Cargo.toml"))
    end)

    it("find_ancestor walks parents from the buffer's directory", function()
      local cwd = vim.fn.getcwd()
      vim.fn.mkdir(cwd .. "/spec/nested", "p")
      vim.fn.writefile({ "" }, cwd .. "/Cargo.toml")
      vim.api.nvim_buf_set_name(buf, cwd .. "/spec/nested/foo.rs")
      local ctx = paneity._build_ctx(buf)
      assert.are.equal(cwd .. "/Cargo.toml", ctx.find_ancestor("Cargo.toml"))
    end)

    it("find_ancestor returns nil when marker is nowhere up the chain", function()
      local ctx = paneity._build_ctx(buf)
      assert.is_nil(ctx.find_ancestor("__definitely_not_there__"))
    end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: three failures — stub returns nil for all calls.

- [ ] **Step 3: Replace the stub**

In `M._build_ctx`, replace the `find_ancestor` stub:

```lua
    find_ancestor = function(name)
      local dir = vim.fn.fnamemodify(bufname, ":p:h")
      while dir and dir ~= "" do
        local candidate = dir .. "/" .. name
        if vim.fn.filereadable(candidate) == 1 or vim.fn.isdirectory(candidate) == 1 then
          return candidate
        end
        local parent = vim.fn.fnamemodify(dir, ":h")
        if parent == dir then return nil end
        dir = parent
      end
      return nil
    end,
```

(Stops when `:h` of a directory equals itself — that's `/` on Unix.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: all three pass.

- [ ] **Step 5: Commit**

```bash
git add lua/paneity/init.lua tests/unit/guess_command_spec.lua
git commit -m "Implement ctx.find_ancestor in guess_command builder"
```

---

## Task 5: `ctx.contents` helper — lazy and memoized

Returns the whole buffer as a newline-joined string. Lazy (not computed until called) and memoized (multiple calls = one underlying read).

**Files:**
- Modify: `lua/paneity/init.lua` (replace stubbed `contents`)
- Modify: `tests/unit/guess_command_spec.lua`

- [ ] **Step 1: Write the failing tests**

Append inside the `_build_ctx` describe block:

```lua
    it("contents returns buffer text joined by newline", function()
      local ctx = paneity._build_ctx(buf)
      assert.are.equal("describe 'foo' do\nend", ctx.contents())
    end)

    it("contents is lazy — does not read the buffer until called", function()
      -- Replace nvim_buf_get_lines so we can detect any read at build time.
      local orig = vim.api.nvim_buf_get_lines
      local reads = 0
      vim.api.nvim_buf_get_lines = function(...)
        reads = reads + 1
        return orig(...)
      end

      local ctx = paneity._build_ctx(buf)
      assert.are.equal(0, reads)
      ctx.contents()
      assert.are.equal(1, reads)

      vim.api.nvim_buf_get_lines = orig
    end)

    it("contents memoizes — repeated calls only read once", function()
      local orig = vim.api.nvim_buf_get_lines
      local reads = 0
      vim.api.nvim_buf_get_lines = function(...)
        reads = reads + 1
        return orig(...)
      end

      local ctx = paneity._build_ctx(buf)
      ctx.contents()
      ctx.contents()
      ctx.contents()
      assert.are.equal(1, reads)

      vim.api.nvim_buf_get_lines = orig
    end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: failures — stub returns "" rather than buffer contents.

- [ ] **Step 3: Replace the stub**

In `M._build_ctx`, replace the `contents` stub:

```lua
    contents = (function()
      local cached
      return function()
        if cached == nil then
          cached = table.concat(
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
        end
        return cached
      end
    end)(),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: all three pass.

- [ ] **Step 5: Commit**

```bash
git add lua/paneity/init.lua tests/unit/guess_command_spec.lua
git commit -m "Implement ctx.contents lazy memoized reader"
```

---

## Task 6: Wire `default_prefill` to the pipeline; minimal `guess_command` defaults

Replace the body of `default_prefill` so it builds ctx + calls the resolver. Add a `guess_command` table to `M.defaults` containing only a `default` handler that preserves today's behavior (`return ctx.relpath`). Shipped per-filetype handlers come in later tasks.

**Files:**
- Modify: `lua/paneity/init.lua` (`default_prefill`, `M.defaults`)
- Modify: `tests/unit/guess_command_spec.lua`

- [ ] **Step 1: Write the failing tests**

Append a new describe block to `tests/unit/guess_command_spec.lua` inside the top-level `describe`:

```lua
  describe("default_prefill via guess_command", function()
    local buf, prev_cwd

    before_each(function()
      prev_cwd = vim.fn.getcwd()
      local tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir, "p")
      vim.cmd("cd " .. vim.fn.fnameescape(tmpdir))

      buf = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(buf, tmpdir .. "/foo.rb")
      vim.bo[buf].filetype = "ruby"
      vim.api.nvim_set_current_buf(buf)
    end)

    after_each(function()
      vim.cmd("cd " .. vim.fn.fnameescape(prev_cwd))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("uses the ruby handler when configured", function()
      paneity.setup({
        keybindings = false,
        guess_command = {
          ruby = function(ctx) return "rspec " .. ctx.relpath end,
        },
      })
      paneity.target_pane_id = "%99"  -- enable new_command path
      local got
      paneity.run = function(cmd) got = cmd end
      require("paneity.shells").bash = {
        get_command = function(prefill, _) got = prefill end,
      }
      paneity.new_command({})
      assert.are.equal("rspec foo.rb", got)
    end)

    it("returns ctx.relpath via the shipped default when no handler matches", function()
      paneity.setup({ keybindings = false })
      paneity.target_pane_id = "%99"
      local got
      require("paneity.shells").bash = {
        get_command = function(prefill, _) got = prefill end,
      }
      vim.bo[buf].filetype = "klingon"
      paneity.new_command({})
      assert.are.equal("foo.rb", got)
    end)
  end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: failures — `default_prefill` still returns relpath unconditionally; the ruby handler test sees "foo.rb" instead of "rspec foo.rb".

- [ ] **Step 3: Update `default_prefill` and `M.defaults`**

Replace the existing `default_prefill` (around `lua/paneity/init.lua:435-440`):

```lua
local function default_prefill()
  if vim.bo.buftype ~= "" then return "" end
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then return "" end
  local ctx = M._build_ctx(0)
  return M._resolve_prefill(ctx, M.config.guess_command)
end
```

Extend `M.defaults` (around `lua/paneity/init.lua:478-498`) to include `guess_command`:

```lua
M.defaults = {
  log_level = vim.log.levels.OFF,
  marker = "🥖🕹️",
  split_direction = nil,
  split_size = nil,
  split_percentage_size = nil,
  shell = "bash",
  termination = {
    key_sequence    = { "C-c", "C-\\" },
    send_term       = true,
    step_timeout_ms = 200,
  },
  guess_command = {
    default = function(ctx) return ctx.relpath end,
  },
  keybindings = {
    toggle = "<leader>tp",
    repeat_command = "<leader><leader>",
    new_command = "<leader>tc",
    page_up = "<PageUp>",
    page_down = "<PageDown>",
    up_enter = "<leader><Up>",
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: new tests pass; all prior unit tests + the popup integration test (which asserts the default prefill is the relpath) still pass.

- [ ] **Step 5: Commit**

```bash
git add lua/paneity/init.lua tests/unit/guess_command_spec.lua
git commit -m "Wire default_prefill through guess_command resolver"
```

---

## Task 7: Extract shipped defaults to `lua/paneity/guess_command.lua`; Makefile-aware `default`

Move the inline `default` handler into a new file so per-filetype handlers can live there alongside it. Update `default` to check for a Makefile at cwd before falling back to relpath. Expose the module at `M.defaults.guess_command`.

**Files:**
- Create: `lua/paneity/guess_command.lua`
- Modify: `lua/paneity/init.lua` (point `M.defaults.guess_command` at the new module)
- Modify: `tests/unit/guess_command_spec.lua`

- [ ] **Step 1: Write the failing tests**

Append a new describe block to `tests/unit/guess_command_spec.lua`:

```lua
  describe("shipped defaults", function()
    local defaults

    before_each(function()
      package.loaded["paneity.guess_command"] = nil
      defaults = require("paneity.guess_command")
    end)

    describe("default handler", function()
      local function ctx_with(makefile_present, relpath)
        return {
          relpath  = relpath or "src/foo.txt",
          has_file = function(name) return makefile_present and name == "Makefile" end,
        }
      end

      it("returns 'make' when a Makefile is at cwd", function()
        assert.are.equal("make", defaults.default(ctx_with(true)))
      end)

      it("falls back to relpath when there is no Makefile", function()
        assert.are.equal("src/foo.txt", defaults.default(ctx_with(false)))
      end)
    end)
  end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: failure — `require("paneity.guess_command")` errors with "module not found".

- [ ] **Step 3: Create `lua/paneity/guess_command.lua`**

```lua
-- lua/paneity/guess_command.lua
--
-- Shipped default handlers for the new-command popup's guess pipeline.
-- Each entry takes a ctx table (see paneity.init `_build_ctx`) and returns
-- either a string (the prefill) or nil to fall through to `default`.
-- `default` is the catch-all and is always called when a filetype handler
-- doesn't match.

local M = {}

function M.default(ctx)
  if ctx.has_file("Makefile") then return "make" end
  return ctx.relpath
end

return M
```

- [ ] **Step 4: Point `M.defaults.guess_command` at the module**

In `lua/paneity/init.lua`, replace the inline `guess_command` block inside `M.defaults` with a require of the new module. `paneity.guess_command` doesn't require `paneity`, so there's no load-order issue with calling `require` inside the table literal.

Find this block (after the Task 6 edit):

```lua
  guess_command = {
    default = function(ctx) return ctx.relpath end,
  },
```

Replace with:

```lua
  guess_command = require("paneity.guess_command"),
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test`
Expected: new tests pass; the Task 6 default-fallback test now expects `make` if your tempdir has a Makefile — it doesn't, so the relpath behavior still holds. Other tests still pass.

- [ ] **Step 6: Commit**

```bash
git add lua/paneity/init.lua lua/paneity/guess_command.lua tests/unit/guess_command_spec.lua
git commit -m "Extract guess_command defaults to module; Makefile-aware default"
```

---

## Task 8: Ship the `ruby` handler

**Files:**
- Modify: `lua/paneity/guess_command.lua`
- Modify: `tests/unit/guess_command_spec.lua`

- [ ] **Step 1: Write the failing tests**

Append inside the `shipped defaults` describe:

```lua
    describe("ruby handler", function()
      local function ctx_with(relpath)
        return { relpath = relpath }
      end

      it("uses rspec for *_spec.rb", function()
        assert.are.equal(
          "bundle exec rspec spec/models/user_spec.rb",
          defaults.ruby(ctx_with("spec/models/user_spec.rb")))
      end)

      it("uses rspec for any file under /spec/", function()
        assert.are.equal(
          "bundle exec rspec spec/support/helper.rb",
          defaults.ruby(ctx_with("spec/support/helper.rb")))
      end)

      it("uses rake test for *_test.rb", function()
        assert.are.equal(
          "bundle exec rake test TEST=test/models/user_test.rb",
          defaults.ruby(ctx_with("test/models/user_test.rb")))
      end)

      it("uses rake test for any file under /test/", function()
        assert.are.equal(
          "bundle exec rake test TEST=test/support/helper.rb",
          defaults.ruby(ctx_with("test/support/helper.rb")))
      end)

      it("falls back to `ruby <relpath>` for non-test files", function()
        assert.are.equal(
          "ruby app/models/user.rb",
          defaults.ruby(ctx_with("app/models/user.rb")))
      end)
    end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: failures — `defaults.ruby` is nil.

- [ ] **Step 3: Implement `ruby` in `lua/paneity/guess_command.lua`**

Add to the module:

```lua
function M.ruby(ctx)
  if ctx.relpath:match("_spec%.rb$") or ctx.relpath:match("/spec/") then
    return "bundle exec rspec " .. ctx.relpath
  end
  if ctx.relpath:match("_test%.rb$") or ctx.relpath:match("/test/") then
    return "bundle exec rake test TEST=" .. ctx.relpath
  end
  return "ruby " .. ctx.relpath
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: all five ruby tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/paneity/guess_command.lua tests/unit/guess_command_spec.lua
git commit -m "Ship ruby handler for guess_command"
```

---

## Task 9: Ship the `rust` handler

**Files:**
- Modify: `lua/paneity/guess_command.lua`
- Modify: `tests/unit/guess_command_spec.lua`

- [ ] **Step 1: Write the failing tests**

Append inside the `shipped defaults` describe:

```lua
    describe("rust handler", function()
      it("returns 'cargo test' when Cargo.toml is in the ancestor chain", function()
        local ctx = {
          relpath = "src/lib.rs",
          find_ancestor = function(name)
            if name == "Cargo.toml" then return "/repo/Cargo.toml" end
          end,
        }
        assert.are.equal("cargo test", defaults.rust(ctx))
      end)

      it("returns nil when Cargo.toml is absent", function()
        local ctx = {
          relpath = "scratch.rs",
          find_ancestor = function() return nil end,
        }
        assert.is_nil(defaults.rust(ctx))
      end)
    end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: failures — `defaults.rust` is nil.

- [ ] **Step 3: Implement `rust`**

Add to `lua/paneity/guess_command.lua`:

```lua
function M.rust(ctx)
  if ctx.find_ancestor("Cargo.toml") then return "cargo test" end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: both rust tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/paneity/guess_command.lua tests/unit/guess_command_spec.lua
git commit -m "Ship rust handler for guess_command"
```

---

## Task 10: Ship the `lua` handler

**Files:**
- Modify: `lua/paneity/guess_command.lua`
- Modify: `tests/unit/guess_command_spec.lua`

- [ ] **Step 1: Write the failing tests**

Append inside the `shipped defaults` describe:

```lua
    describe("lua handler", function()
      it("returns 'make test' for *_spec.lua with a Makefile at cwd", function()
        local ctx = {
          relpath  = "tests/unit/foo_spec.lua",
          has_file = function(name) return name == "Makefile" end,
        }
        assert.are.equal("make test", defaults.lua(ctx))
      end)

      it("returns nil for *_spec.lua without a Makefile", function()
        local ctx = {
          relpath  = "tests/unit/foo_spec.lua",
          has_file = function() return false end,
        }
        assert.is_nil(defaults.lua(ctx))
      end)

      it("returns nil for non-spec lua files", function()
        local ctx = {
          relpath  = "lua/paneity/init.lua",
          has_file = function(name) return name == "Makefile" end,
        }
        assert.is_nil(defaults.lua(ctx))
      end)
    end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: failures — `defaults.lua` is nil.

- [ ] **Step 3: Implement `lua`**

Add to `lua/paneity/guess_command.lua`:

```lua
function M.lua(ctx)
  if ctx.relpath:match("_spec%.lua$") and ctx.has_file("Makefile") then
    return "make test"
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: all three lua tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/paneity/guess_command.lua tests/unit/guess_command_spec.lua
git commit -m "Ship lua handler for guess_command"
```

---

## Task 11: Integration test — end-to-end ruby spec prefill

One end-to-end case mirroring the user experience: real tmux, real nvim, a real `_spec.rb` file. Asserts the popup is prefilled with `bundle exec rspec spec/foo_spec.rb`.

**Files:**
- Create: `tests/integration/guess_command_spec.lua`

- [ ] **Step 1: Write the test**

```lua
-- tests/integration/guess_command_spec.lua
--
-- End-to-end smoke test for the filetype-aware prefill pipeline.
-- Opens a real *_spec.rb in nvim under tmux, triggers the new-command
-- popup, and asserts the prefill matches the shipped ruby handler.

local tmux_session = require("tests.integration.support.tmux_session")

local REPO_ROOT = vim.fn.fnamemodify(
  vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h")

local POPUP_HOME = REPO_ROOT .. "/tests/integration/support/popup_home"

describe("guess_command (integration)", function()
  local session

  before_each(function()
    session = tmux_session.start({ name = "paneity_guess" })

    -- Create spec/foo_spec.rb in the session tmpdir so nvim's cwd
    -- becomes its parent and the prefill is `spec/foo_spec.rb`.
    vim.fn.mkdir(session.tmpdir .. "/spec", "p")
    local spec_file = session:path("spec/foo_spec.rb")
    vim.fn.writefile(
      { "RSpec.describe 'foo' do", "  it { }", "end" },
      spec_file)

    session:start_nvim({
      file = spec_file,
      init_lines = {
        "vim.env.HOME = " .. string.format("%q", POPUP_HOME),
        "vim.env.XDG_DATA_HOME = " .. string.format("%q", session.tmpdir .. "/xdg"),
        "vim.cmd('cd " .. session.tmpdir .. "')",
        string.format("vim.opt.runtimepath:prepend(%q)", REPO_ROOT),
        "vim.g.mapleader = ' '",
        "require('paneity').setup({})",
      },
    })
  end)

  after_each(function()
    session:destroy()
  end)

  it("prefills the popup with the shipped ruby handler's command", function()
    session:send_keys("Space t p")
    assert.is_true(session:wait_for_pane_count(2),
      "expected paneity to create a second pane within 3s")

    session:send_keys("Space t c")
    assert.is_true(session:wait_for_popup_session(),
      "expected popup session within 3s")
    assert.is_true(session:wait_for_popup_prompt(),
      "expected popup bash prompt within 5s")

    local popup_text = session:popup_pane_text()
    assert.is_truthy(
      popup_text:find("bundle exec rspec spec/foo_spec.rb", 1, true),
      "expected shipped ruby handler prefill at popup prompt; got: " .. popup_text)
  end)
end)
```

- [ ] **Step 2: Run the test**

Run: `make test`
Expected: the integration test passes. If it fails, common causes:
- The buffer's filetype isn't `ruby` — nvim's filetype detection may need an extra moment. The default `start_nvim` blocks until paneity is loaded; if filetype isn't set yet at that point, add `vim.bo.filetype = 'ruby'` to `init_lines` (after the file is opened) or wait for filetype detection.
- The popup prefill includes the relpath but not the rspec wrapper — that means the ruby handler isn't being reached; check that `M.config.guess_command.ruby` is the shipped function.

- [ ] **Step 3: Commit**

```bash
git add tests/integration/guess_command_spec.lua
git commit -m "Integration test: ruby handler prefills the new-command popup"
```

---

## Task 12: README documentation

**Files:**
- Modify: `README.md` (new section after "Setting a new command")

- [ ] **Step 1: Add the documentation section**

Open `README.md`. After the `### M.new_command(opts)` block (around line 47, after the "opts.prompt was removed" note) and before `## Requirements`, insert:

````markdown
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
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Document guess_command in README"
```

---

## Self-review notes

**Spec coverage:**
- Resolution flow (spec §"Resolution flow") → Task 1 (`_resolve_prefill`) + Task 6 (`default_prefill` wiring).
- ctx table (spec §"ctx table") → Tasks 2–5.
- Exposed defaults at `paneity.defaults.guess_command.<ft>` → Task 7 (`require("paneity.guess_command")` becomes the value of `M.defaults.guess_command`; `M.defaults` is already module-exposed).
- Shipped defaults (spec §"Shipped defaults") → Tasks 7–10.
- File layout (spec §"File layout") → Tasks 7, 11, 12.
- Testing (spec §"Testing") → unit tests woven into Tasks 1–10; integration in Task 11.
- "Behavior preserved" (spec §"Behavior preserved") → Task 6 reuses the existing buftype/bufname short-circuits; existing `popup_command_spec.lua` covers the relpath default and must still pass after Task 6.

**Override / `false`-disable** is in the resolver (Task 1) and documented (Task 12); no separate task needed.

**Type consistency:** Helper names match across tasks (`has_file`, `find_ancestor`, `contents`). Resolver signature `M._resolve_prefill(ctx, guess_command)` is consistent across Tasks 1, 6, and the README. Module path `paneity.guess_command` matches between Tasks 7–10 and the require call.

**Risk to flag:** Task 11's integration test depends on nvim's filetype detection firing automatically for `.rb` files in the headless test environment. If that's flaky, the fallback noted in Task 11 Step 2 is to set the filetype explicitly in `init_lines`.
