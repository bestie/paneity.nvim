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
  end)

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
  end)
end)
