local function log(string)
  if not vim.g.paneity_debug then
    return
  end

  local file = io.open("paneity.log", "a")
  file:write(string .. "\n")
  file:close()
end

local function shell_exec(command)
  log("Executing: " .. command)
  local handle = io.popen(command)
  local output = handle:read("*a")
  handle:close()
  return output:gsub("^%s*(.-)%s*$", "%1")
end

local function send_command(pane_id, keys)
  -- C-a C-k ensures any existing input is cleared without killing the current prompt or ringing the bell
  -- C-m is another readline binding for ENTER
  shell_exec(string.format("tmux send-keys -t %s C-a C-k '%s' C-m", pane_id, keys))
end

return {
  send_command = send_command,
  shell_exec = shell_exec,
  log = log,
}
