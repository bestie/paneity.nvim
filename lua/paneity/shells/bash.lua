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
[ -r /etc/profile ]    && . /etc/profile
[ -r ~/.bash_profile ] && . ~/.bash_profile
[ -r ~/.bashrc ]       && . ~/.bashrc

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

__paneity_prefill_now() {
  READLINE_LINE="$PANEITY_PREFILL"
  READLINE_POINT=${#PANEITY_PREFILL}
}
bind -x '"\C-x\C-p": __paneity_prefill_now'

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

  local env_flags = table.concat({
    "-e PANEITY_PREFILL="  .. shesc(prefill or ""),
    "-e PANEITY_CAPTURE="  .. shesc(capture_path),
    "-e PANEITY_HISTFILE=" .. shesc(histfile),
    "-e PANEITY_READY="    .. shesc(ready_path),
    "-e PANEITY_CWD="      .. shesc(cwd),
  }, " ")

  -- Detached single-pane session running bash. The session is the
  -- popup's addressable handle; when bash exits the session dies.
  local _, code = tmux(string.format(
    "new-session -d -s %s -x 200 -y 50 %s bash --rcfile %s",
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

  local function on_popup_exit()
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

  -- Prefill: poll for the ready marker, then send the trigger key to
  -- the helper session. PROMPT_COMMAND writes the ready file before
  -- readline starts, so the keystroke lands inside the bind -x handler
  -- which populates READLINE_LINE from $PANEITY_PREFILL.
  if prefill and prefill ~= "" then
    local timer = uv.new_timer()
    timer:start(25, 25, vim.schedule_wrap(function()
      if vim.fn.filereadable(ready_path) == 1 then
        timer:stop()
        timer:close()
        tmux(string.format(
          "send-keys -t %s:0.0 C-x C-p", shesc(session_name)))
      end
    end))
    -- Safety: stop the timer if the popup exits before ready fires.
    local original_cleanup = cleanup_and_callback
    cleanup_and_callback = function(captured)
      if not timer:is_closing() then
        pcall(function() timer:stop(); timer:close() end)
      end
      original_cleanup(captured)
    end
  end

  -- Run `display-popup -E` async. TMUX is unset so the inner
  -- `tmux attach-session` doesn't refuse on nesting; tmux finds the
  -- right socket via $TMUX_TMPDIR / default discovery.
  local popup_cmd = string.format(
    "TMUX= tmux display-popup -E 'tmux attach-session -t %s'",
    shesc(session_name))

  vim.fn.jobstart({ "sh", "-c", popup_cmd }, {
    on_exit = function() vim.schedule(on_popup_exit) end,
  })
end

return M
