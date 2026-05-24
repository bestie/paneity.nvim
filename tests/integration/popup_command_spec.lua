-- tests/integration/popup_command_spec.lua
--
-- Integration tests for the popup-shell command input feature.
-- Tests drive a real bash popup inside the tmux sandbox via
-- send-keys to the helper session (paneity-popup-<token>).

local tmux_session = require("tests.integration.support.tmux_session")
local fs           = require("tests.integration.support.fs")
local wait         = require("tests.integration.support.wait")

local REPO_ROOT = vim.fn.fnamemodify(
  vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h:h")

local POPUP_HOME = REPO_ROOT .. "/tests/integration/support/popup_home"

describe("popup-shell command input", function()
  local session
  local log_file
  local sample_file

  before_each(function()
    session = tmux_session.start({ name = "paneity_popup" })
    log_file    = session:path("cmd.log")
    sample_file = session:path("sample.txt")
    vim.fn.writefile({ "sample contents" }, sample_file)

    -- Inner nvim runs with HOME pointed at the fixture so the popup's
    -- bash sources our known .bashrc (PS1, PANEITY_TEST_MARKER, ptest).
    session:start_nvim({
      file = sample_file,
      init_lines = {
        "vim.env.HOME = " .. string.format("%q", POPUP_HOME),
        string.format("vim.opt.runtimepath:prepend(%q)", REPO_ROOT),
        "vim.g.mapleader = ' '",
        "require('paneity').setup({})",
      },
    })
  end)

  after_each(function()
    session:destroy()
  end)

  local function activate_paneity()
    session:send_keys("Space t p")
    assert.is_true(session:wait_for_pane_count(2),
      "expected paneity to create a second pane within 3s")
    for _, id in ipairs(session:pane_ids()) do
      if id ~= session.nvim_pane_id then return id end
    end
    error("could not find paneity target pane id")
  end

  it("captures a command typed in the popup and runs it in the target", function()
    activate_paneity()

    -- <leader>tc -> M.new_command -> popup. With sample.txt as the
    -- active buffer, the default prefill is the buffer's file path
    -- relative to nvim's cwd.
    session:send_keys("Space t c")
    assert.is_true(session:wait_for_popup_session(),
      "expected popup session within 3s")
    assert.is_true(session:wait_for_popup_prompt(),
      "expected popup bash prompt within 5s")

    -- Default prefill should be visible in the popup pane. This proves
    -- the prefill mechanism wired up; the rest of the test exercises
    -- capture + transmission with a clean, controllable command.
    local popup_text = session:popup_pane_text()
    assert.is_truthy(popup_text:find("sample.txt", 1, true),
      "expected default prefill (sample.txt) at popup prompt; got: " .. popup_text)

    -- Clear the prefill (C-a -> BOL, C-k -> kill to EOL), then type a
    -- known command that writes a token to the log file. The target
    -- pane's bash will execute it.
    local token = fs.random_token()
    session:send_keys_to_popup("C-a C-k")
    session:send_keys_to_popup(string.format(
      "%s Enter",
      vim.fn.shellescape("echo " .. token .. " >> " .. log_file)))

    -- Popup closes when bash exits via __paneity_capture.
    assert.is_true(session:wait_for_no_popup_session(),
      "expected popup session to disappear within 3s")

    -- Target pane should have run the echo and written the token.
    assert.is_true(wait.until_true(function()
      return #fs.read_lines(log_file) >= 1
    end, 5000), "expected target pane to write log line within 5s")

    assert.are.equal(token, fs.read_lines(log_file)[1])
  end)
end)
