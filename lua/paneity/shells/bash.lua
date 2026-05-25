-- lua/paneity/shells/bash.lua
--
-- Bash adapter for the shell strategy. Launches a detached tmux
-- helper session running `bash --rcfile <generated>` and overlays it
-- with `tmux display-popup -E`. Enter inside the popup writes the
-- current readline buffer to a capture file and exits bash; the
-- adapter reads the file and invokes cb.

local uv = vim.uv or vim.loop

local M = {}

-- Public test handle: name of the active helper session while a popup
-- is open, nil otherwise. Integration tests target this for send-keys.
M._active_session = nil

-- Embedded rcfile contents. Sourcing order matters: user init first
-- (aliases, completions, PS1), then paneity overrides so anything the
-- user binds to Enter or sets as HISTFILE gets stomped. `bind -x` runs
-- the function in the current shell, so `exit 0` from __paneity_capture
-- terminates bash before any command parsing happens.
local RCFILE = [=[
[ -r /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -r /etc/bashrc ]      && . /etc/bashrc
[ -r ~/.bashrc ]        && . ~/.bashrc

cd "$PANEITY_CWD" 2>/dev/null || true

export HISTFILE="$PANEITY_HISTFILE"
export HISTSIZE=1000
export HISTFILESIZE=1000
history -c
history -r

__paneity_capture() {
  printf '%s\n' "$READLINE_LINE" > "$PANEITY_CAPTURE"
  if [ -n "$READLINE_LINE" ]; then
    history -s -- "$READLINE_LINE"
    history -a
  fi
  exit 0
}
bind -x '"\C-m": __paneity_capture'
bind -x '"\C-j": __paneity_capture'

trap 'exit 130' INT

__paneity_signal_ready() {
  if [ -z "$_paneity_ready_sent" ]; then
    : > "$PANEITY_READY"
    _paneity_ready_sent=1
  fi
}
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }__paneity_signal_ready"
]=]

local function random_token()
  math.randomseed(os.time() + math.floor(os.clock() * 1e6))
  return string.format("%08x%08x",
    math.random(0, 2 ^ 31 - 1), math.random(0, 2 ^ 31 - 1))
end

local function temp_path(suffix)
  return string.format("/tmp/paneity-%s-%s", suffix, random_token())
end

local function write_file(path, contents)
  local f, err = io.open(path, "w")
  if not f then error("paneity: cannot write " .. path .. ": " .. (err or "?")) end
  f:write(contents)
  f:close()
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function unlink(path)
  if path then pcall(os.remove, path) end
end

local function default_histfile()
  local data = vim.env.XDG_DATA_HOME or (vim.env.HOME .. "/.local/share")
  return data .. "/paneity/history"
end

local function tmux(args)
  local out = vim.fn.system("tmux " .. args)
  return out, vim.v.shell_error
end

local function shesc(s)
  return vim.fn.shellescape(s or "")
end

function M.get_command(prefill, cb)
  local session_name = "paneity-popup-" .. random_token()
  local rcfile_path  = temp_path("rcfile")
  local capture_path = temp_path("capture")
  local ready_path   = temp_path("ready")
  local histfile     = default_histfile()
  local cwd          = vim.fn.getcwd()

  -- HISTFILE parent must exist before bash tries to read/write it.
  vim.fn.mkdir(vim.fn.fnamemodify(histfile, ":h"), "p")
  write_file(rcfile_path, RCFILE)

  -- Pass HOME explicitly so the popup bash sources the same ~/.bashrc
  -- that the calling nvim sees, even when tmux's server was started with
  -- a different HOME (common in tests that redirect HOME to a fixture dir).
  local env_flags = table.concat({
    "-e HOME="             .. shesc(vim.env.HOME or ""),
    "-e PANEITY_CAPTURE="  .. shesc(capture_path),
    "-e PANEITY_HISTFILE=" .. shesc(histfile),
    "-e PANEITY_READY="    .. shesc(ready_path),
    "-e PANEITY_CWD="      .. shesc(cwd),
  }, " ")

  -- Detached single-pane session running bash. The session is the
  -- popup's addressable handle; when bash exits the session dies.
  local _, code = tmux(string.format(
    "new-session -d -s %s -x 200 -y 50 %s bash --rcfile %s -i",
    shesc(session_name), env_flags, shesc(rcfile_path)))

  if code ~= 0 then
    unlink(rcfile_path)
    cb(nil)
    return
  end

  M._active_session = session_name

  local cleaned_up = false
  local cleanup_and_callback
  cleanup_and_callback = function(captured)
    if cleaned_up then return end
    cleaned_up = true
    M._active_session = nil
    -- Kill the session if it still exists (e.g. error path before bash
    -- exited normally). Errors here are deliberately ignored.
    tmux("kill-session -t " .. shesc(session_name) .. " 2>/dev/null")
    unlink(rcfile_path)
    unlink(capture_path)
    unlink(ready_path)
    cb(captured)
  end

  local function collect_captured()
    local raw = read_file(capture_path)
    if not raw or raw == "" or raw == "\n" then
      cleanup_and_callback(nil)
      return
    end
    local trimmed = raw:gsub("\n$", "")
    if trimmed == "" then
      cleanup_and_callback(nil)
    else
      cleanup_and_callback(trimmed)
    end
  end

  -- Poll for the capture file (written when bash exits via Enter) or
  -- for the helper session to disappear (e.g. C-c exit or display-popup
  -- not available). This is the primary lifecycle mechanism: we do NOT
  -- rely on display-popup's exit code so the adapter works even in
  -- headless test environments where display-popup has no client.
  local watcher = uv.new_timer()
  watcher:start(50, 50, vim.schedule_wrap(function()
    -- Session gone -> bash exited; read whatever was captured.
    local sess_out = vim.fn.system(
      "tmux list-sessions -F '#{session_name}' 2>/dev/null")
    local session_alive = sess_out:find(session_name, 1, true) ~= nil

    if vim.fn.filereadable(capture_path) == 1 or not session_alive then
      if not watcher:is_closing() then
        pcall(function() watcher:stop(); watcher:close() end)
      end
      collect_captured()
    end
  end))

  -- Stop the watcher when cleanup runs (e.g. from an error path).
  local original_cleanup = cleanup_and_callback
  cleanup_and_callback = function(captured)
    if not watcher:is_closing() then
      pcall(function() watcher:stop(); watcher:close() end)
    end
    original_cleanup(captured)
  end

  -- Prefill: poll for the ready marker, then type the prefill text
  -- directly into the helper session. PROMPT_COMMAND writes the ready
  -- file before readline starts, so the literal characters arrive at
  -- an idle prompt. -l makes send-keys treat the argument as a literal
  -- string to type rather than tmux key names; each char self-inserts
  -- via readline with no bind, no chord, no INPUTRC dependency.
  if prefill and prefill ~= "" then
    local prefill_timer = uv.new_timer()
    prefill_timer:start(25, 25, vim.schedule_wrap(function()
      if vim.fn.filereadable(ready_path) == 1 then
        if not prefill_timer:is_closing() then
          pcall(function() prefill_timer:stop(); prefill_timer:close() end)
        end
        tmux(string.format(
          "send-keys -t %s:0.0 -l %s",
          shesc(session_name), shesc(prefill)))
      end
    end))
    -- Stop prefill timer if cleanup runs before ready fires.
    local prev_cleanup = cleanup_and_callback
    cleanup_and_callback = function(captured)
      if not prefill_timer:is_closing() then
        pcall(function() prefill_timer:stop(); prefill_timer:close() end)
      end
      prev_cleanup(captured)
    end
  end

  -- Launch display-popup as best-effort visual overlay. The socket flag
  -- ensures we reach the right tmux server even when TMUX_TMPDIR differs
  -- between the outer test process and the inner nvim. Clearing TMUX
  -- avoids the nesting guard; -S restores server reachability.
  -- If display-popup fails (e.g. no attached client in headless tests),
  -- the watcher above still detects bash exiting and calls the callback.
  local tmux_env = vim.env.TMUX or ""
  local socket_path = tmux_env:match("^([^,]+),") or ""
  local socket_arg  = socket_path ~= "" and ("-S " .. socket_path .. " ") or ""
  local popup_cmd = string.format(
    "TMUX= tmux %sdisplay-popup -E 'TMUX= tmux %sattach-session -t %s'",
    socket_arg, socket_arg, shesc(session_name))

  vim.fn.jobstart({ "sh", "-c", popup_cmd }, {
    on_exit = function() end,  -- handled by watcher above
  })
end

return M
