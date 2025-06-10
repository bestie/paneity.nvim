local M = {}

M.version = "0.0.1"

local function log(string)
  if not vim.g.paneity_debug then
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
  shell_exec(string.format("tmux send-keys -t %s C-c", target_pane_id))
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

local function term_foreground_process(pane_info)
  local fg_process = pane_info.command
  local shell_pid = pane_info.pid
  local kill_command = string.format("pgrep -P %s | xargs kill -TERM", shell_pid)
  local output = ""

  if shell_pid ~= "" and fg_process ~= "bash" and fg_process ~= "fish" and fg_process ~= "zsh" then
    output = shell_exec(kill_command)
    -- naively assume that by the time kill has returned and the keys are sent the process has exited
    -- blocking here could cause problems and it's been working well enough so far
  end

  return output
end

local function send_to_tmux_pane(target_pane_id, command)
  local pane_info = get_pane_info_by_id(target_pane_id)
  log("Pane info: " .. vim.inspect(pane_info))

  term_foreground_process(pane_info)

  send_command(target_pane_id, command)
end

local function mark_pane(pane_id, marker)
  local tmux_border_format = shell_exec("tmux show-option -g pane-border-format")
  local new_tmux_border_format = string.gsub(tmux_border_format, "#P", marker .. "#P", 1)
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

local function fzf_selection_ui(fzf, menu_items, on_selection)
  log("FZF: " .. vim.inspect(menu_items))

  local selection
  local capture_selection = function(captured)
    selection = captured
  end

  fzf.fzf_exec(menu_items, {
    prompt = "Select a target pane > ",
    fzf_opts = {
      ["--cycle"] = true,
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

M.set_target_pane_id = function(pane_id)
  M.target_pane_id = pane_id
  mark_pane(M.target_pane_id, M.config.marker)
end

local function pane_was_selected(selection)
  log("Selection: " .. vim.inspect(selection))

  local target_pane_id
  local panes = get_pane_info()
  local selected_pane_index = tonumber(vim.split(selection, ":")[1]) or 0

  if selected_pane_index == 0 then
    log("creating new pane")
    target_pane_id = open_new_pane()
  elseif selected_pane_index > 1 then
    log("picking existing pane" .. selection)
    target_pane_id = panes[selected_pane_index]["id"]
  else
    log("ooops" .. selection)
  end

  log("new_target_pane ID " .. vim.inspect(target_pane_id))

  if not target_pane_id then
    print_error("could not set target pane")
  end

  if target_pane_id then
    M.set_target_pane_id(target_pane_id)
    print_message("enabled ✅")
  else
    print_error("error selecting pane 🍞🥖")
  end
end

local function choose_tmux_pane()
  local current_pane_id = os.getenv("TMUX_PANE")
  local panes = get_pane_info()
  log("Panes: " .. vim.inspect(panes))

  local menu_items = {
    "0: New Pane (default))",
  }

  for _, pane in ipairs(panes) do
    if pane.id ~= current_pane_id then
      table.insert(menu_items, string.format("%s: ID: %s running: %s", pane.index, pane.id, pane.command))
      unmark_pane(pane.id)
    end
  end

  if #menu_items > 1 then
    local fzf = require("fzf-lua")
    fzf_selection_ui(fzf, menu_items, pane_was_selected)
    log("loading fzf")
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

function M.toggle()
  if M.target_pane_id then
    unmark_pane(M.target_pane_id)
    M.target_pane_id = nil
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
    send_to_tmux_pane(M.target_pane_id, M.previous_command)
  else
    print_error("must have a target pane and a command to repeat")
  end
end

function M.new_command()
  if M.target_pane_id then
    local user_command = vim.fn.input("Command to run: ")
    send_to_tmux_pane(M.target_pane_id, user_command)
    M.previous_command = user_command
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

local defaults = {
  marker = "🥖🕹️",
  split_direction = nil,
  split_size = nil,
  split_percentage_size = nil,
  keybindings = {
    toggle = "<leader>tp",
    repeat_command = "<leader><leader>",
    new_command = "<leader>tc",
    page_up = "<PageUp>",
    page_down = "<PageDown>",
    up_enter = "<leader><Up>",
  }
}

local function merge_config(user_config)
  return vim.tbl_deep_extend("force", defaults, user_config or {})
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
  log("Paneity setup")
  -- retain some state
  M.target_pane_id = M.target_pane_id or nil
  M.previous_command = M.previous_command or ""

  local config = merge_config(user_config)

  if config["keybindings"] ~= false then
    setup_keybindings(config.keybindings)
  end

  M.config = config

  register_cleanup()
end

return M
