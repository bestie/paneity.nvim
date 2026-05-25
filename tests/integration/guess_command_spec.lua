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
        string.format("vim.cmd('cd %s')", vim.fn.fnameescape(session.tmpdir)),
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
