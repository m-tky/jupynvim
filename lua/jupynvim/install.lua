-- Download prebuilt jupynvim-core binary from GitHub releases.
--
-- Used by the lazy.nvim `build` hook so users don't need a Rust toolchain.
-- Falls back to cargo build when the platform is unsupported, the binary
-- isn't published for the current tag, or the download fails.

local M = {}

local REPO = "sheng-tse/jupynvim"

-- Map vim.uv.os_uname() to Rust target triple matching CI artifact names.
local function detect_target()
  local u = vim.uv.os_uname()
  local sys = u.sysname    -- "Darwin", "Linux"
  local mach = u.machine   -- "arm64", "aarch64", "x86_64"
  if sys == "Darwin" then
    if mach == "arm64" then return "aarch64-apple-darwin" end
    if mach == "x86_64" then return "x86_64-apple-darwin" end
  elseif sys == "Linux" then
    if mach == "x86_64" then return "x86_64-unknown-linux-gnu" end
    if mach == "aarch64" then return "aarch64-unknown-linux-gnu" end
  end
  return nil
end

-- Get the plugin's currently-checked-out tag. Lazy.nvim usually checks out
-- a specific tag for users who pin one; defaults to the latest tag for
-- users who track main without pinning.
local function detect_tag(plugin_dir)
  local out = vim.fn.system({ "git", "-C", plugin_dir, "describe", "--tags", "--exact-match" })
  if vim.v.shell_error == 0 then return vim.trim(out) end
  out = vim.fn.system({ "git", "-C", plugin_dir, "describe", "--tags", "--abbrev=0" })
  if vim.v.shell_error == 0 then return vim.trim(out) end
  return nil
end

local function build_from_source(plugin_dir)
  local manifest = plugin_dir .. "/core/Cargo.toml"
  vim.notify("jupynvim: building from source via cargo (no prebuilt available)",
    vim.log.levels.INFO)
  local out = vim.fn.system({ "cargo", "build", "--release", "--manifest-path", manifest })
  if vim.v.shell_error ~= 0 then
    error(("jupynvim: cargo build failed: %s"):format(out))
  end
end

-- Main entry. Called from the lazy.nvim build hook.
-- plugin: lazy plugin spec (has `.dir`, the install path).
-- Returns true on prebuilt-download success, false if it fell back to cargo.
function M.run(plugin)
  local plugin_dir = (plugin and plugin.dir) or vim.fn.expand("~/.local/share/nvim/lazy/jupynvim")

  local target = detect_target()
  if not target then
    build_from_source(plugin_dir)
    return false
  end

  local tag = detect_tag(plugin_dir)
  if not tag then
    build_from_source(plugin_dir)
    return false
  end

  local url = string.format(
    "https://github.com/%s/releases/download/%s/jupynvim-core-%s",
    REPO, tag, target
  )
  local dest_dir = plugin_dir .. "/core/target/release"
  vim.fn.mkdir(dest_dir, "p")
  local dest = dest_dir .. "/jupynvim-core"

  vim.notify(("jupynvim: downloading prebuilt binary %s..."):format(tag),
    vim.log.levels.INFO)
  local out = vim.fn.system({
    "curl", "-fsSL", "--retry", "3", "--retry-delay", "2",
    "-o", dest, url,
  })
  if vim.v.shell_error ~= 0 then
    vim.notify(("jupynvim: download failed (%s), falling back to cargo build"):format(out),
      vim.log.levels.WARN)
    build_from_source(plugin_dir)
    return false
  end

  vim.fn.system({ "chmod", "+x", dest })
  -- macOS gatekeeper rejects unsigned downloaded binaries by default. Clear
  -- the quarantine attribute so the binary runs without "developer cannot
  -- be verified" prompts.
  if vim.uv.os_uname().sysname == "Darwin" then
    vim.fn.system({ "xattr", "-cr", dest })
  end

  vim.notify(("jupynvim: prebuilt %s installed"):format(target), vim.log.levels.INFO)
  return true
end

-- Exposed for testing: just the URL the run() would download.
function M._url_for(tag, target)
  return string.format(
    "https://github.com/%s/releases/download/%s/jupynvim-core-%s",
    REPO, tag, target
  )
end

M._detect_target = detect_target
M._detect_tag = detect_tag

return M
