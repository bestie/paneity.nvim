local M = {}

M.version = "0.0.1"

local function log(string)
  if M.config.log_level == vim.log.levels.OFF then
    return
  end

  local file = io.open("/tmp/paneity.log", "a")
  file:write(string .. "\n")
  file:close()
end

local function print_error(message)
  print("Paneity error: " .. message)
end

local function print_message(message)
  print("Paneity: " .. message)
end

local function shell_exec(command)
  log("Executing: " .. command)
  local handle = io.popen(command)
  local output = handle:read("*a")
  handle:close()
  return output:gsub("^%s*(.-)%s*$", "%1")
end

local function send_command(target_pane_id, keys)
  shell_exec(string.format("tmux send-keys -t %s '%s' C-m", target_pane_id, keys))
end

local pane_list_format = "#{pane_index}:#{pane_id}:#{pane_pid}:#{pane_current_command}"

local function get_pane_info()
  local output = shell_exec("tmux list-panes -F '" .. pane_list_format .. "'")

  local pane_array = {}
  for line in string.gmatch(output, "([^\n]+)") do
    local pane_index, pane_id, pane_pid, pane_command = line:match("([^:]*):([^:]*):([^:]*):([^:]*)")
    table.insert(pane_array, {
      index = pane_index,
      id = pane_id,
      command = pane_command,
      pid = pane_pid,
    })
  end

  return pane_array
end

local function get_pane_info_by_id(pane_id)
  local all_panes = get_pane_info()
  log("looking for current pane: " .. vim.inspect(pane_id))
  for _, pane in ipairs(all_panes) do
    log("checking pane: " .. vim.inspect(pane))
    if pane["id"] == pane_id then
      return pane
    end
  end
  return nil
end

-- Internal seams (underscore-prefixed) — exposed on M so unit tests can stub
-- them. Not part of the public API; production behavior is unchanged.
function M._send_keys(pane_id, key)
  shell_exec(string.format("tmux send-keys -t %s '%s'", pane_id, key))
end

function M._pane_pid(pane_id)
  local output = shell_exec(string.format("tmux display -p -t %s '#{pane_pid}'", pane_id))
  return tonumber(output)
end

function M._tty_foreground_pgid(pane_pid)
  if pane_pid == nil then return nil end
  local output = shell_exec(string.format("ps -o tpgid= -p %s", pane_pid))
  return tonumber(output)
end

function M._kill(pid, signal)
  shell_exec(string.format("kill -%s %s", signal, pid))
end

function M._prompt_termination_choice()
  local choice = vim.fn.confirm(
    "Paneity: foreground didn't respond. Type anyway, cancel, or kill -TERM?",
    "&Type anyway\n&Cancel\nkill -&TERM",
    2  -- default: Cancel
  )
  if choice == 1 then return "type"
  elseif choice == 3 then return "term"
  else return "cancel" end
end

local function shell_is_foreground(pane_id)
  local pane_pid = M._pane_pid(pane_id)
  if not pane_pid then return false end
  local tpgid = M._tty_foreground_pgid(pane_pid)
  return tpgid ~= nil and tpgid == pane_pid
end

local function normalize_command(command)
  if command == nil then return nil end
  return (command:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1"))
end

local function kill_foreground(pane_id)
  local pane_pid = M._pane_pid(pane_id)
  local tpgid = M._tty_foreground_pgid(pane_pid)
  if tpgid and tpgid ~= pane_pid then
    M._kill(tpgid, "TERM")
    return true
  end
  return false
end

local function wait_for_shell(pane_id, timeout_ms)
  return vim.wait(timeout_ms, function()
    return shell_is_foreground(pane_id)
  end, 50)
end

function M._terminate_foreground(pane_id, new_command)
  local termination = M.config.termination

  -- Lazy clear: if the shell is already foreground, no paneity command is
  -- currently running, so any retained ownership state is stale.
  if shell_is_foreground(pane_id) then
    M.last_paneity_command = nil
  end

  local key_sequence = termination.key_sequence

  -- Step 1: always send the first key (C-c by default). Harmless at an idle
  -- prompt, clears any partial command, interrupts running processes.
  M._send_keys(pane_id, key_sequence[1])
  if wait_for_shell(pane_id, termination.step_timeout_ms) then
    M.last_paneity_command = nil
    return true
  end

  -- Gate: don't escalate against processes paneity didn't start.
  if not M.last_paneity_command then
    return false
  end

  -- Step 2: remaining keys in the sequence (gated on paneity ownership).
  for i = 2, #key_sequence do
    M._send_keys(pane_id, key_sequence[i])
    if wait_for_shell(pane_id, termination.step_timeout_ms) then
      M.last_paneity_command = nil
      return true
    end
  end

  -- Step 3: TERM the foreground process group. Doubly gated:
  -- (a) send_term must be enabled, (b) the new command must match the last
  -- paneity-issued command (after whitespace normalization).
  if termination.send_term and new_command
     and normalize_command(new_command) == normalize_command(M.last_paneity_command) then
    if kill_foreground(pane_id) then
      if wait_for_shell(pane_id, termination.step_timeout_ms) then
        M.last_paneity_command = nil
        return true
      end
    end
  end

  return false
end

local function mark_pane(pane_id, marker)
  local tmux_border_format = shell_exec("tmux show-option -g pane-border-format")
  -- tmux's default `pane-border-format` uses `#{pane_index}`; older
  -- configs may still use the `#P` short alias. Try the long form
  -- first, fall back to the short.
  local new_tmux_border_format, n = string.gsub(
    tmux_border_format, "#{pane_index}", marker .. "#{pane_index}", 1)
  if n == 0 then
    new_tmux_border_format = string.gsub(
      tmux_border_format, "#P", marker .. "#P", 1)
  end
  shell_exec(string.format("tmux set-option -p -t %s %s", pane_id, new_tmux_border_format))
end

local function unmark_pane(pane_id)
  local tmux_border_format = shell_exec("tmux show-option -g pane-border-format")
  shell_exec(string.format("tmux set-option -p -t %s %s", pane_id, tmux_border_format))
end

local function open_new_pane()
  local split_direction = ""
  if M.config.split_direction == "horizontal" then
    split_direction = "-h"
  elseif M.config.split_direction == "vertical" then
    split_direction = "-v"
  end

  local size_option = ""
  if M.config.split_size_percentage ~= nil then
    size_option = string.format("-p %d", M.config.split_size_percentage)
  elseif M.config.split_size ~= nil then
    size_option = string.format("-l %d", M.config.split_size)
  end

  -- Log the size option and split direction for debugging
  log("Split direction: " .. split_direction)
  log("Size option: " .. size_option)

  local pane_id = shell_exec('tmux split-window -d -P -F "#{pane_id}" -c "$(pwd)" ' .. size_option .. ' ' .. split_direction)
  return pane_id
end

local function fzf_selection_ui(prompt, menu_items, on_selection)
  local fzf = require("fzf-lua")
  log("FZF: " .. vim.inspect(menu_items))

  local selection

  -- move the "New pane" option to the end of the list
  if menu_items[1] == "New pane" then
    local new_pane_item = table.remove(menu_items, 1)
    table.insert(menu_items, new_pane_item)
  end

  fzf.fzf_exec(menu_items, {
    prompt = prompt,
    fzf_opts = {
      ["--bind"] = "start:down",  -- doesn't work, bind option not passed through
    },
    winopts = {
      height = #menu_items + 3,
      row = 1,    -- bottom
      col = 4,    -- characters
      width = 50, -- characters
    },
    actions = {
      ["default"] = function(selected)
        if selected and #selected > 0 then
          on_selection(selected[1])
        end
      end,
    },
  })

  return selection
end

local function native_selection_ui(prompt, menu_items, on_selection)
  log("Native selection: " .. vim.inspect(menu_items))

  -- prepend items with index
  for i, item in ipairs(menu_items) do
    menu_items[i] = string.format("%d) %s", i - 1, item)
  end

  table.insert(menu_items, 1, prompt)

  local selection = vim.fn.inputlist(menu_items)
  on_selection(menu_items[selection+2])
end

M.set_target_pane_id = function(pane_id)
  M.target_pane_id = pane_id
  M.last_paneity_command = nil
  mark_pane(M.target_pane_id, M.config.marker)
end

local function pane_was_selected(selection)
  local target_pane = nil

  log("Selection: " .. vim.inspect(selection))

  -- extract pane ID from the selection string
  local selected_pane_id = selection:match("ID:(%S+)")
  log("selected_pane_id: " .. vim.inspect(selected_pane_id))

  if selected_pane_id then
    target_pane = get_pane_info_by_id(selected_pane_id)
    log("target_pane: " .. vim.inspect(target_pane))
  else
    local new_pane_id = open_new_pane()
    target_pane = get_pane_info_by_id(new_pane_id)
    log("New pane created: " .. vim.inspect(target_pane))
  end

  if target_pane then
    M.set_target_pane_id(target_pane.id)
    print_message("enabled ✅ 👉 " .. target_pane.id)
    log("enabled ✅ 👉 " .. target_pane.id)
  else
    print_error("error selecting pane 🍞🥖")
    log("error selecting pane 🍞🥖")
  end
end

local function choose_tmux_pane()
  local current_pane_id = os.getenv("TMUX_PANE")
  local panes = get_pane_info()
  log("Panes: " .. vim.inspect(panes))

  local menu_items = { }

  table.insert(menu_items, "New pane")

  for _, pane in ipairs(panes) do
    if pane.id ~= current_pane_id then
      table.insert(menu_items, string.format("Pane:%s ID:%s running: %s", pane.index, pane.id, pane.command))
      unmark_pane(pane.id)
    end
  end

  if #menu_items > 1 then
    prompt = "Select a target pane > "

    local ok, fzf = pcall(require, "fzf-lua")
    if ok then
      fzf_selection_ui(prompt, menu_items, pane_was_selected)
    else
      native_selection_ui(prompt, menu_items, pane_was_selected)
    end
  else
    local new_pane_id = open_new_pane()
    M.set_target_pane_id(new_pane_id)
  end
end

local function get_tmux_info()
  local tmux_var = os.getenv("TMUX")
  local tmux_pane_var = os.getenv("TMUX_PANE")

  if tmux_var then
    local parts = vim.split(tmux_var, ",")
    if #parts ~= 3 then
      print_error("'TMUX' environment variable not recognised")
      return
    end

    local info = {
      socket_path = parts[1],
      session_id = parts[2],
      window_id = parts[3],
      pane_id = tmux_pane_var,
    }

    return info
  else
    print_error("Not running in tmux")
  end
end

local function send_page_key_to_tmux(key)
  local copy_mode_command = string.format("tmux copy-mode -t%s -e", M.target_pane_id)
  shell_exec(copy_mode_command)

  local page_command = string.format("tmux send-keys -t%s '%s'", M.target_pane_id, key)
  shell_exec(page_command)
end

-- Public functions ------------------------------------------------------------

function M.run(command)
  local pane_id = M.target_pane_id
  local ok = M._terminate_foreground(pane_id, command)

  if not ok then
    local choice = M._prompt_termination_choice()
    if choice == "cancel" then
      return
    elseif choice == "term" then
      if kill_foreground(pane_id) then
        wait_for_shell(pane_id, M.config.termination.step_timeout_ms)
      end
    end
    -- "type" falls through: send the command into whatever's there.
  end

  send_command(pane_id, command)
  M.previous_command = command
  M.last_paneity_command = command
end

function M.status_line()
  if not get_tmux_info() then
    return ""
  end

  local string = "🥖"
  if M.target_pane_id then
    string = string .. " [" .. M.target_pane_id .. "]"
  else
    string = string .. "[💤]"
  end

  return string
end

function M.toggle()
  if M.target_pane_id then
    unmark_pane(M.target_pane_id)
    M.target_pane_id = nil
    M.last_paneity_command = nil
    print_message("disabled ❌")
  else
    M.set_target_pane()
  end
end

function M.set_target_pane()
  local tmux_info = get_tmux_info()

  if not tmux_info then
    return
  end

  M.target_pane_id = nil
  for _, pane in ipairs(get_pane_info()) do
    unmark_pane(pane.id)
  end

  choose_tmux_pane()
end

function M.repeat_command()
  if M.previous_command ~= "" and M.target_pane_id then
    M.run(M.previous_command)
  else
    print_error("must have a target pane and a command to repeat")
  end
end

function M.new_command(opts)
  opts = vim.tbl_deep_extend("force", {
    prompt = "Command to run: ",
    prefill = "",
    post_exec = false
  }, opts or {})

  if M.target_pane_id then
    vim.ui.input({ prompt = opts.prompt, default = opts.prefill }, function(command)
      if command then
        print_message("Running command: " .. command)
        M.run(command)
        if opts.post_exec then
          opts.post_exec(command)
        end
      end
    end)
  else
    print_error("no target pane set.")
  end
end

function M.up_enter()
  shell_exec(string.format("tmux send-keys -t%s C-c", M.target_pane_id))
  shell_exec(string.format("tmux send-keys -t%s Up ENTER", M.target_pane_id))
end

function M.page_up()
  send_page_key_to_tmux("PageUp")
end

function M.page_down()
  send_page_key_to_tmux("PageDown")
end

-- Setup and configuration -----------------------------------------------------

M.defaults = {
  log_level = vim.log.levels.OFF,
  marker = "🥖🕹️",
  split_direction = nil,
  split_size = nil,
  split_percentage_size = nil,
  shell = "bash",
  termination = {
    key_sequence    = { "C-c", "C-\\" },
    send_term       = true,
    step_timeout_ms = 200,
  },
  keybindings = {
    toggle = "<leader>tp",
    repeat_command = "<leader><leader>",
    new_command = "<leader>tc",
    page_up = "<PageUp>",
    page_down = "<PageDown>",
    up_enter = "<leader><Up>",
  }
}

local function merge_defaults(user_config)
  return vim.tbl_deep_extend("force", M.defaults, user_config or {})
end

local function setup_keybindings(bindings)
  local function opts(description)
    return { noremap = true, silent = true, desc = "Paneity " .. description }
  end

  if bindings.toggle then
    vim.keymap.set("n", bindings.toggle, M.toggle, opts("enable/disable"))
  end
  if bindings.repeat_command then
    vim.keymap.set("n", bindings.repeat_command, M.repeat_command, opts("re-run command"))
  end
  if bindings.new_command then
    vim.keymap.set("n", bindings.new_command, M.new_command, opts("run a new command"))
  end
  if bindings.page_up then
    vim.keymap.set("n", bindings.page_up, M.page_up, opts("scroll the pane up"))
  end
  if bindings.page_down then
    vim.keymap.set("n", bindings.page_down, M.page_down, opts("scroll the pane down"))
  end
  if bindings.up_enter then
    vim.keymap.set("n", bindings.up_enter, M.up_enter, opts("re-run via ↑ ENTER"))
  end
end

local function cleanup()
  if M.target_pane_id then
    unmark_pane(M.target_pane_id)
  end
end

local function register_cleanup()
  vim.api.nvim_create_autocmd("VimLeave", {
    callback = cleanup,
  })
end

function M.setup(user_config)
  -- retain some state
  M.target_pane_id = M.target_pane_id or nil
  M.previous_command = M.previous_command or ""
  M.last_paneity_command = M.last_paneity_command or nil

  local config = merge_defaults(user_config)

  if config["keybindings"] ~= false then
    setup_keybindings(config.keybindings)
  end

  M.config = config
  log("configuration: " .. vim.inspect(config))

  register_cleanup()
end

return M
