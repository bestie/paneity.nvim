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
        "vim.env.XDG_DATA_HOME = " .. string.format("%q", session.tmpdir .. "/xdg"),
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

  it("does not touch the target pane when the popup is cancelled with C-c", function()
    activate_paneity()

    session:send_keys("Space t c")
    assert.is_true(session:wait_for_popup_session(),
      "expected popup session within 3s")
    assert.is_true(session:wait_for_popup_prompt(),
      "expected popup bash prompt within 5s")

    -- Ctrl-C triggers `trap 'exit 130' INT` in the rcfile. Bash exits
    -- without writing the capture file → adapter calls cb(nil).
    session:send_keys_to_popup("C-c")

    assert.is_true(session:wait_for_no_popup_session(),
      "expected popup session to close after C-c within 3s")

    -- No log file should have been created; previous_command unchanged
    -- (still nil since we never ran anything). The simplest assertion:
    -- the log file is absent.
    assert.is_false(fs.exists(log_file),
      "expected no command to have been sent to the target")
  end)

  it("sources the user's bashrc inside the popup", function()
    activate_paneity()

    session:send_keys("Space t c")
    assert.is_true(session:wait_for_popup_session(),
      "expected popup session within 3s")
    assert.is_true(session:wait_for_popup_prompt(),
      "expected popup bash prompt within 5s")

    -- The fixture .bashrc sets PS1='paneity_test> '. If we see that
    -- string in the popup pane, bash inside the popup sourced our
    -- ~/.bashrc — which is what "user init was loaded" means in
    -- practice. wait_for_popup_prompt already polls for this; the
    -- explicit assertion documents the intent of the test.
    local popup_text = session:popup_pane_text()
    assert.is_truthy(popup_text:find("paneity_test>", 1, true),
      "expected fixture PS1 in popup, proving .bashrc was sourced; got: "
      .. popup_text)

    -- Cancel so after_each can tear down cleanly.
    session:send_keys_to_popup("C-c")
    assert.is_true(session:wait_for_no_popup_session())
  end)

  it("uses opts.prefill = '' to suppress the default file-path prefill", function()
    activate_paneity()

    -- Invoke M.new_command directly via :lua so we can pass opts. We
    -- need to wait for the popup session as usual, then assert the
    -- prompt line has nothing after the prompt suffix.
    session:send_keys(
      vim.fn.shellescape(":lua require('paneity').new_command({ prefill = '' })")
      .. " Enter")

    assert.is_true(session:wait_for_popup_session(),
      "expected popup session within 3s")
    assert.is_true(session:wait_for_popup_prompt(),
      "expected popup bash prompt within 5s")

    -- Give the prefill polling timer a few ticks to NOT fire (it
    -- shouldn't, because prefill is empty). Then capture the pane and
    -- assert the trailing line is just the prompt with no content.
    vim.wait(200)

    local lines = {}
    for line in (session:popup_pane_text() .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, line)
    end
    -- Find the last non-blank line; it should end with the prompt
    -- suffix and have nothing after it.
    local last
    for i = #lines, 1, -1 do
      if lines[i] ~= "" then last = lines[i]; break end
    end
    assert.is_truthy(last and last:match("paneity_test>%s*$"),
      "expected empty input after prompt; got last line: " .. tostring(last))

    -- Clean up: cancel the popup so after_each can destroy the session.
    session:send_keys_to_popup("C-c")
    assert.is_true(session:wait_for_no_popup_session())
  end)

  it("sources ~/.profile when neither ~/.bash_profile nor ~/.bash_login exists", function()
    activate_paneity()

    session:send_keys("Space t c")
    assert.is_true(session:wait_for_popup_session(),
      "expected popup session within 3s")
    assert.is_true(session:wait_for_popup_prompt(),
      "expected popup bash prompt within 5s")

    -- Fixture ~/.profile sets PANEITY_PROFILE_LOADED=yes, and
    -- ~/.bashrc embeds that variable into PS1. So a popup that
    -- sourced ~/.profile shows "yes_paneity_test>" at its prompt;
    -- one that didn't shows "no_paneity_test>".
    local popup_text = session:popup_pane_text()
    assert.is_truthy(popup_text:find("yes_paneity_test>", 1, true),
      "expected ~/.profile to be sourced (PS1 prefix 'yes_'); got: " .. popup_text)

    session:send_keys_to_popup("C-c")
    assert.is_true(session:wait_for_no_popup_session())
  end)
end)
