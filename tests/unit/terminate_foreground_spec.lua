-- Unit tests for paneity._terminate_foreground — first-key branch only.
--
-- These tests stub the two seams exposed on the module (`_pane_current_command`
-- and `_send_keys`) so no real tmux is required. The full escalation ladder is
-- covered end-to-end by the integration tests; here we just assert which key
-- (if any) gets sent on the first dispatch given the foreground process name.

describe("terminate_foreground (unit)", function()
  local paneity
  local sent_keys

  before_each(function()
    package.loaded["paneity"] = nil
    paneity = require("paneity")
    paneity.setup({ keybindings = false })
    sent_keys = {}
    paneity._send_keys = function(_, key) table.insert(sent_keys, key) end
  end)

  -- Build a stub for `_pane_current_command`: returns the next value from
  -- `values` on each call, sticking on the last value once exhausted. The
  -- "stick on last" behavior matters because `wait_for_shell` polls until the
  -- foreground becomes a shell — we want the predicate to eventually succeed.
  local function queue(values)
    local i = 0
    return function()
      i = i + 1
      return values[i] or values[#values]
    end
  end

  it("does not send any keys when foreground is already a shell", function()
    paneity._pane_current_command = queue({ "bash" })
    paneity._terminate_foreground("%1")
    assert.are.same({}, sent_keys)
  end)

  it("sends C-d to a known REPL", function()
    paneity._pane_current_command = queue({ "irb", "bash" })
    paneity._terminate_foreground("%1")
    assert.are.same({ "C-d" }, sent_keys)
  end)

  it("sends C-c to a generic foreground process", function()
    paneity._pane_current_command = queue({ "vim", "bash" })
    paneity._terminate_foreground("%1")
    assert.are.same({ "C-c" }, sent_keys)
  end)
end)
