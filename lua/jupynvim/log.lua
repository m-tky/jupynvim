-- Tiny logger — writes to ~/.cache/jupynvim/lua.log
local M = {}

local cache = vim.fn.stdpath("cache") .. "/jupynvim"
vim.fn.mkdir(cache, "p")
local path = cache .. "/lua.log"
local fp = nil

local function open()
  if fp then return fp end
  fp = io.open(path, "a")
  return fp
end

local levels = { trace = 0, debug = 1, info = 2, warn = 3, error = 4 }
local current = levels.info

function M.set_level(name)
  current = levels[name] or levels.info
end

local function write(level, msg)
  if levels[level] < current then return end
  local f = open()
  if not f then return end
  local stamp = os.date("%H:%M:%S")
  f:write(string.format("[%s] [%s] %s\n", stamp, level, msg))
  f:flush()
end

function M.trace(...) write("trace", table.concat({ ... }, " ")) end
function M.debug(...) write("debug", table.concat({ ... }, " ")) end
function M.info(...)  write("info",  table.concat({ ... }, " ")) end
function M.warn(...)  write("warn",  table.concat({ ... }, " ")) end
function M.error(...) write("error", table.concat({ ... }, " ")) end

function M.path() return path end

return M
