-- Integration test for paneity's terminate_foreground (SIGINT happy path).
--
-- Strategy: spin up an isolated tmux server by setting TMUX_TMPDIR to a fresh
-- temp dir. Both `vim.fn.system` calls here and the plugin's `io.popen` calls
-- pick this up, so all `tmux` invocations share the same private socket and
-- never touch the developer's real session.

local function trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function tmux(args)
  return trim(vim.fn.system("tmux " .. args))
end

local function capture_pane(pane_id)
  return vim.fn.system("tmux capture-pane -p -t " .. pane_id)
end

local function wait_until(predicate, timeout_ms, interval_ms)
  interval_ms = interval_ms or 50
  return vim.wait(timeout_ms, predicate, interval_ms)
end

describe("terminate_foreground", function()
  local tmux_tmpdir
  local pane_id
  local session = "paneity_test"

  before_each(function()
    tmux_tmpdir = trim(vim.fn.system("mktemp -d"))
    vim.env.TMUX_TMPDIR = tmux_tmpdir

    -- Detached session so tmux won't try to attach to a TTY.
    tmux(string.format("new-session -d -s %s -x 200 -y 50", session))
    pane_id = tmux(string.format("display -p -t %s '#{pane_id}'", session))
    assert.is_truthy(pane_id:match("^%%%d+$"))

    package.loaded["paneity"] = nil
    local paneity = require("paneity")
    paneity.setup({})
    paneity.set_target_pane_id(pane_id)
  end)

  after_each(function()
    -- Clear target_pane_id on the live module *before* killing the server, so
    -- the VimLeave cleanup autocmd (which closes over M) doesn't try to talk
    -- to a dead socket when nvim exits.
    require("paneity").target_pane_id = nil

    vim.fn.system("tmux kill-server")
    if tmux_tmpdir and tmux_tmpdir ~= "" then
      vim.fn.system("rm -rf " .. vim.fn.shellescape(tmux_tmpdir))
    end
    vim.env.TMUX_TMPDIR = nil
    package.loaded["paneity"] = nil
  end)

  it("sends SIGINT to a foreground blocker then runs the new command", function()
    -- Start a long-running blocker in the target pane.
    tmux(string.format("send-keys -t %s 'sleep 30' C-m", pane_id))

    -- Wait for the foreground command to become `sleep`.
    local saw_sleep = wait_until(function()
      local fg = trim(vim.fn.system(
        string.format("tmux display -p -t %s '#{pane_current_command}'", pane_id)
      ))
      return fg == "sleep"
    end, 2000, 50)
    assert.is_true(saw_sleep, "expected pane_current_command to become 'sleep' within 2s")

    -- Drive paneity: this should C-c the sleep, then send the new command.
    require("paneity").run("echo PANEITY_OK")

    -- Poll the pane content until we see the marker.
    local saw_marker = wait_until(function()
      return capture_pane(pane_id):find("PANEITY_OK", 1, true) ~= nil
    end, 2000, 50)

    assert.is_true(saw_marker,
      "expected PANEITY_OK in pane content within 2s; got:\n" .. capture_pane(pane_id))
  end)
end)
