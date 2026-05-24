-- tests/integration/support/fs.lua
--
-- Small file helpers for integration tests.

local M = {}

-- Write `lines` to `path`, one line per entry. Overwrites any existing file.
function M.write(path, lines)
  vim.fn.writefile(lines, path)
end

-- Read `path` into a list of lines. Returns an empty list if the file is
-- absent, so tests can poll with `#read_lines(path) >= N`.
function M.read_lines(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local lines = {}
  for line in f:lines() do
    table.insert(lines, line)
  end
  f:close()
  return lines
end

function M.exists(path)
  return vim.fn.filereadable(path) == 1
end

-- A unique 16-hex-char token suitable for tagging command output so tests
-- can detect exactly which run produced a given line in a log file.
function M.random_token()
  math.randomseed(os.time() + math.floor(os.clock() * 1e6))
  return string.format("%08x%08x",
    math.random(0, 2 ^ 31 - 1), math.random(0, 2 ^ 31 - 1))
end

return M
