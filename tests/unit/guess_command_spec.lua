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
