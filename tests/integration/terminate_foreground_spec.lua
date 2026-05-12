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

  it("escalates to SIGQUIT when the foreground process ignores SIGINT", function()
    -- Lua script run via `nvim -l` — nvim is already on PATH via mise, so we
    -- don't need any extra runtime. pane_current_command will be `nvim`,
    -- which is not in SHELLS, so terminate_foreground engages the ladder.
    local script_path = tmux_tmpdir .. "/blocker.lua"
    local sig_log = tmux_tmpdir .. "/signals.log"

    local fd = assert(io.open(script_path, "w"))
    fd:write(table.concat({
      "local sig_log = arg[1]",
      "local function write(name)",
      "  local f = io.open(sig_log, 'a')",
      "  f:write(name .. '\\n')",
      "  f:close()",
      "end",
      -- Paneity sends C-c twice (200ms apart) before escalating to SIGQUIT.
      -- We dedupe so the log records each signal type exactly once; without
      -- this the script would log SIGINT twice and break the strict assertion.
      "local sigint = vim.uv.new_signal()",
      "sigint:start('sigint', function()",
      "  write('SIGINT')",
      "end)",
      "local sigquit = vim.uv.new_signal()",
      "sigquit:start('sigquit', function() write('SIGQUIT'); os.exit(0) end)",
      "write('READY')",
      "vim.uv.run()",
      "",
    }, "\n"))
    fd:close()

    require("paneity").run(string.format("nvim -l %s %s", script_path, sig_log))

    -- Wait for the script to install its handlers and announce READY.
    local function read_log()
      local f = io.open(sig_log, "r")
      if not f then return "" end
      local content = f:read("*a") or ""
      f:close()
      return content
    end

    local ready = wait_until(function()
      return read_log():find("READY", 1, true) ~= nil
    end, 3000, 50)
    assert.is_true(ready, "expected script to write READY within 3s")

    -- Drive paneity: C-c -> handler logs SIGINT, C-\ -> handler logs SIGQUIT and exits.
    require("paneity").run("echo PANEITY_QUIT_OK")

    local saw_marker = wait_until(function()
      return capture_pane(pane_id):find("PANEITY_QUIT_OK", 1, true) ~= nil
    end, 5000, 50)
    assert.is_true(saw_marker,
      "expected PANEITY_QUIT_OK after escalation; pane:\n" .. capture_pane(pane_id))

    local lines = {}
    for line in read_log():gmatch("[^\n]+") do
      table.insert(lines, line)
    end

    assert.are.same({ "READY", "SIGINT", "SIGQUIT" }, lines)
  end)

  it("sends C-c to a foreground bash script and prompts when gate blocks escalation", function()
    -- Verifies FIXED behavior: paneity now sends C-c even when pane_current_command
    -- is 'bash' (a running script), then the gate blocks escalation (since paneity
    -- didn't start the script), and the prompt is invoked.
    -- The script's QUIT trap is load-bearing: it prevents SIGQUIT from
    -- silently killing bash (the default disposition) if the gate were ever
    -- to wrongly escalate, so the strict `{ "READY", "SIGINT" }` assertion
    -- catches the regression instead of passing for the wrong reason.
    local script_path = tmux_tmpdir .. "/script.sh"
    local sig_log = tmux_tmpdir .. "/signals.log"

    local fd = assert(io.open(script_path, "w"))
    fd:write(table.concat({
      "log=\"$1\"",
      "trap 'echo SIGINT >> \"$log\"' INT",
      "trap 'echo SIGQUIT >> \"$log\"' QUIT",
      "echo READY >> \"$log\"",
      "while true; do read line; done",
      "",
    }, "\n"))
    fd:close()

    tmux(string.format("send-keys -t %s 'bash %s %s' C-m",
      pane_id, script_path, sig_log))

    local function read_log()
      local f = io.open(sig_log, "r")
      if not f then return "" end
      local content = f:read("*a") or ""
      f:close()
      return content
    end

    local ready = wait_until(function()
      return read_log():find("READY", 1, true) ~= nil
    end, 3000, 50)
    assert.is_true(ready, "expected script to write READY within 3s")

    -- Verify the test setup: tmux reports the foreground as plain `bash`,
    -- indistinguishable from an idle interactive shell prompt. This is the
    -- scenario the fix addresses.
    local fg = trim(vim.fn.system(
      string.format("tmux display -p -t %s '#{pane_current_command}'", pane_id)
    ))
    assert.are.equal("bash", fg,
      "precondition failed: expected pane_current_command='bash' but got '" .. fg .. "'")

    -- Stub the prompt to choose Cancel (no command will be sent).
    local prompted = false
    require("paneity")._prompt_termination_choice = function()
      prompted = true
      return "cancel"
    end

    require("paneity").run("echo PANEITY_OK")

    -- Wait for SIGINT to land in the log (or fail fast if it doesn't).
    local saw_signal = wait_until(function()
      return read_log():find("SIGINT", 1, true) ~= nil
    end, 1000, 20)
    assert.is_true(saw_signal, "expected SIGINT in log within 1s; got: " .. read_log())

    -- C-c WAS sent (SIGINT trap fired). The gate blocked escalation since
    -- paneity didn't start the script. The prompt was invoked.
    local lines = {}
    for line in read_log():gmatch("[^\n]+") do
      table.insert(lines, line)
    end
    assert.are.same({ "READY", "SIGINT" }, lines)
    assert.is_true(prompted, "expected the UI prompt to be invoked")

    -- And the new command was NOT sent (user picked Cancel).
    local pane_content = capture_pane(pane_id)
    assert.is_nil(pane_content:find("PANEITY_OK", 1, true),
      "expected PANEITY_OK not to appear; got:\n" .. pane_content)
  end)
end)
