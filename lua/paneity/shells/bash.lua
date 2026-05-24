-- lua/paneity/shells/bash.lua
--
-- Bash adapter for the shell strategy. Launches a detached tmux
-- helper session running `bash --rcfile <generated>` and overlays it
-- with `tmux display-popup -E`. Enter inside the popup writes the
-- current readline buffer to a capture file and exits bash; the
-- adapter reads the file and invokes cb.
--
-- This stub returns cb(nil) immediately; real launch logic is added
-- in subsequent tasks.

local M = {}

-- Public test handle: name of the active helper session while a popup
-- is open, nil otherwise. Integration tests target this for send-keys.
M._active_session = nil

function M.get_command(prefill, cb)
  cb(nil)
end

return M
