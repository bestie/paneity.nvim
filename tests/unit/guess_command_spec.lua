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
  end)
end)
