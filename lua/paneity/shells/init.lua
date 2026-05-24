-- lua/paneity/shells/init.lua
--
-- Registry of shell adapters. Each adapter exposes a single async
-- method, get_command(prefill, cb), which presents a shell-like input
-- experience and calls cb with either the captured command string or
-- nil if the user cancelled.

return {
  bash = require("paneity.shells.bash"),
}
