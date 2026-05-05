-- jupynvim — VSCode-style Jupyter notebook editing in Neovim.
--
-- Usage (lazy.nvim-style):
--   require("jupynvim").setup({ core_path = "/path/to/jupynvim-core" })
--
-- Or just call setup({}) — it'll auto-detect the binary in this repo.

local M = {}

local Notebook = require("jupynvim.notebook")
local Render   = require("jupynvim.render")
local RPC      = require("jupynvim.rpc")
local Keymaps  = require("jupynvim.keymaps")
local Image    = require("jupynvim.image")
local Log      = require("jupynvim.log")

M.client = nil    -- single backend process shared by all notebooks
M.config = {
  core_path = nil,
  python = nil,
  log_level = "info",
  -- "placeholder": real PNG via Kitty Unicode placeholder protocol
  --              (Ghostty 1.3.1+ supports it; image stays anchored to cell)
  -- "kitty":       real PNG via direct placement (lives at fixed screen coords)
  -- "chafa":       ASCII art fallback for terminals without graphics support
  image_renderer = "placeholder",
}

-- ---------- backend helpers ----------

local function locate_core()
  if M.config.core_path then return M.config.core_path end
  -- Look for the binary next to this lua file: ../../core/target/release/jupynvim-core
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  local dir = vim.fn.fnamemodify(src, ":h:h:h")  -- .../jupynvim
  local candidate = dir .. "/core/target/release/jupynvim-core"
  if vim.fn.executable(candidate) == 1 then return candidate end
  return "jupynvim-core"
end

local function ensure_client()
  if M.client and M.client.job then return M.client end
  local path = locate_core()
  Log.info("spawning core: " .. path)
  M.client = RPC.spawn({
    cmd = { path },
    env = vim.tbl_extend("force", vim.fn.environ(), {
      JUPYNVIM_LOG = M.config.log_level,
    }),
    on_exit = function(code)
      M.client = nil
      vim.schedule(function()
        vim.notify("jupynvim-core exited (code=" .. code .. ")", vim.log.levels.WARN)
      end)
    end,
  })
  -- Attach the controlling TTY for native Kitty graphics
  local tty_path = vim.env.JUPYNVIM_TTY or "/dev/tty"
  Image.attach(M.client, tty_path)

  -- Set up notification handlers
  M.client:on("cell_event", function(args)
    -- args is the params array: [{session_id, cell_id, event}]
    local p = args[1] or args
    M._handle_cell_event(p)
  end)
  M.client:on("kernel_event", function(args)
    local p = args[1] or args
    Log.debug("kernel_event: " .. vim.inspect(p):sub(1, 200))
  end)
  return M.client
end

function M._handle_cell_event(p)
  if not p or not p.session_id then
    Log.warn("cell_event missing session_id: " .. vim.inspect(p):sub(1, 200))
    return
  end
  Log.debug("cell_event cell=" .. tostring(p.cell_id) .. " kind=" .. tostring(p.event and p.event.kind))
  for buf, nb in pairs(Notebook.all()) do
    if nb.session_id == p.session_id then
      nb:apply_cell_event(p.cell_id, p.event or {})
      -- EAGER image transmission — must use the SAME renderer as the active
      -- config so the cache entry matches what render_cell expects.
      local ev = p.event or {}
      if ev.kind == "display_data" or ev.kind == "execute_result" then
        if ev.data then
          local b64 = ev.data["image/png"]
          if type(b64) == "table" then b64 = table.concat(b64, "") end
          if type(b64) == "string" and b64 ~= "" and Image.supported() then
            nb.image_ids = nb.image_ids or {}
            local renderer = M.config.image_renderer or "chafa"
            Image.ensure_transmitted(p.cell_id, b64, function(id)
              if id then
                nb.image_ids[p.cell_id] = id
                -- Re-render so build_output_virt_lines picks up the
                -- newly-cached image data (placeholder rows or ascii).
                vim.schedule(function() Render.refresh(nb, vim.fn.bufwinid(buf)) end)
              end
            end, { renderer = renderer })
          end
        end
      end
      vim.schedule(function()
        Render.refresh(nb, vim.fn.bufwinid(buf))
      end)
      return
    end
  end
  Log.warn("no buf for session " .. tostring(p.session_id))
end

-- ---------- buffer lifecycle ----------

M._opening = M._opening or {}

function M.open(path, opts)
  opts = opts or {}
  ensure_client()
  local abs = vim.fn.fnamemodify(path, ":p")

  -- Idempotency #1: if a notebook for this path is already alive AND we're not
  -- being asked to force-reload, just refocus and re-render.
  local existing_buf = vim.fn.bufnr(abs)
  if existing_buf > 0 then
    local existing_nb = Notebook.get(existing_buf)
    if existing_nb and not opts.force then
      vim.api.nvim_set_current_buf(existing_buf)
      Render.refresh(existing_nb, vim.api.nvim_get_current_win())
      return existing_buf
    end
    -- :e! / force reload: tear down old session before creating new one
    if existing_nb and opts.force then
      pcall(function()
        ensure_client():call("close", { session_id = existing_nb.session_id }, function() end)
      end)
      Notebook.remove(existing_buf)
      pcall(function() require("jupynvim.image").clear_all() end)
    end
  end

  -- Idempotency #2: re-entrancy guard. Two BufReadCmds for the same path race
  -- on `call_sync`; only the first should proceed.
  if M._opening[abs] then
    return existing_buf > 0 and existing_buf or nil
  end
  M._opening[abs] = true

  local err, result = M.client:call_sync("open", { path = abs }, 5000)
  if err then
    M._opening[abs] = nil
    vim.notify("jupynvim open failed: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local sid = result.session_id
  local snap = result.snapshot

  -- Create or reuse the buffer
  local buf = vim.fn.bufnr(abs, true)
  vim.api.nvim_buf_set_name(buf, abs)
  vim.api.nvim_buf_set_option(buf, "buftype", "acwrite")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_option(buf, "filetype", language_filetype(snap))

  local nb = Notebook.create(buf, abs, sid, snap)
  M._populate_buffer(nb)
  M._attach_autocmds(buf)
  Keymaps.attach(buf, M)

  vim.api.nvim_set_current_buf(buf)
  Render.refresh(nb, vim.api.nvim_get_current_win())
  M._opening[abs] = nil

  -- Force a single window for the notebook buffer. Other plugins (LazyVim
  -- defaults, snacks.dashboard, neo-tree, etc.) sometimes auto-split on
  -- :edit, which makes the cells appear duplicated. Close everything except
  -- the current window's view of this buffer.
  local wins = vim.fn.win_findbuf(buf)
  if #wins > 1 then
    local cur_win = vim.api.nvim_get_current_win()
    for _, w in ipairs(wins) do
      if w ~= cur_win then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end

  -- Auto-start kernel based on notebook metadata
  vim.defer_fn(function() M.start_kernel(buf) end, 50)
  return buf
end

function language_filetype(snap)
  local meta = snap.metadata or {}
  local kspec = meta.kernelspec or {}
  local lang = kspec.language or meta.language_info and meta.language_info.name
  if not lang then return "python" end
  -- Map known kernel languages to Neovim filetypes
  local map = { python = "python", julia = "julia", r = "r", javascript = "javascript", typescript = "typescript" }
  return map[lang:lower()] or "python"
end

function M._populate_buffer(nb)
  local lines = nb:to_lines()
  vim.api.nvim_buf_set_option(nb.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(nb.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(nb.buf, "modified", false)
  -- wrap=false because wrapped lines break border alignment on subsequent
  -- visual rows. sidescrolloff=999 keeps cursor centered horizontally so
  -- left border stays visible.
  -- wrap=true + linebreak + breakindent: long markdown wraps at word boundaries,
  --   continuation rows aligned to first row's indent.
  -- showbreak="│ ": prepend "│ " on EVERY wrapped continuation row (left border
  --   appears on all visual rows, not just the first).
  for _, win in ipairs(vim.fn.win_findbuf(nb.buf)) do
    vim.api.nvim_win_call(win, function()
      vim.cmd("setlocal signcolumn=yes:2 conceallevel=2 concealcursor=nc wrap linebreak breakindent")
      vim.cmd([[setlocal showbreak=\│\ ]])
    end)
  end
end

function M._attach_autocmds(buf)
  local group = vim.api.nvim_create_augroup("Jupynvim_" .. buf, { clear = true })

  -- Force window options + close duplicates whenever the notebook buf appears.
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinNew", "WinEnter" }, {
    group = group, buffer = buf,
    callback = function()
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local wins = vim.fn.win_findbuf(buf)
        for _, win in ipairs(wins) do
          vim.api.nvim_win_call(win, function()
            vim.cmd("setlocal signcolumn=yes:2 conceallevel=2 concealcursor=nc wrap linebreak breakindent")
            vim.cmd([[setlocal showbreak=\│\ ]])
          end)
        end
        if #wins > 1 then
          for i = 2, #wins do
            pcall(vim.api.nvim_win_close, wins[i], true)
          end
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group, buffer = buf,
    callback = function()
      local nb = Notebook.get(buf)
      if not nb then return end
      M._save(nb)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group, buffer = buf,
    callback = function()
      local nb = Notebook.get(buf)
      if not nb then return end
      -- Light-weight: re-render borders only (no backend round-trip)
      Render.refresh(nb, vim.fn.bufwinid(buf))
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group, buffer = buf,
    callback = function()
      local nb = Notebook.get(buf)
      if nb and nb.session_id then
        ensure_client():call("close", { session_id = nb.session_id }, function() end)
      end
      Notebook.remove(buf)
      pcall(Image.delete_all)
    end,
  })
  -- Refresh borders whenever window dimensions or buffer focus changes —
  -- width is computed from the active window, so cells need re-rendering
  -- when switching between buffers/windows or resizing.
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "BufWinEnter", "BufEnter", "WinEnter" }, {
    group = group, buffer = buf,
    callback = function()
      local nb = Notebook.get(buf)
      if not nb then return end
      vim.schedule(function() Render.refresh(nb, vim.fn.bufwinid(buf)) end)
    end,
  })
  -- Note: we do NOT re-place images on scroll. With Ghostty 1.3 the placement
  -- escape interleaves with Neovim's own TUI writes, causing the image to land
  -- at unpredictable screen positions on every re-draw. Placing once at run
  -- time is the cleanest behavior until Ghostty fully implements Unicode
  -- placeholder mode (which lets the image stick to buffer text).
end

function M._save(nb)
  nb:sync_from_buffer()
  local cl = ensure_client()
  local Embedded = require("jupynvim.embedded")
  local incoming = {}
  for _, c in ipairs(nb.cells) do
    local src = c.source or ""
    -- Markdown cells: restore original embedded data:image/...;base64,XXX URIs
    -- before saving so the .ipynb on disk keeps them intact.
    if c.cell_type == "markdown" then
      src = Embedded.postprocess(c.id, src)
    end
    table.insert(incoming, {
      id = c.id,
      cell_type = c.cell_type or "code",
      source = src,
    })
  end
  cl:call("replace_cells", { session_id = nb.session_id, cells = incoming }, function(err, res)
    if err then
      vim.notify("replace_cells failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    -- Update local ids in case any "new_*" placeholders got assigned real ids
    if res and res.ids then
      for i, new_id in ipairs(res.ids) do
        if nb.cells[i] then nb.cells[i].id = new_id end
      end
    end
    cl:call("save", { session_id = nb.session_id }, function(serr)
      if serr then
        vim.notify("save failed: " .. tostring(serr), vim.log.levels.ERROR)
        return
      end
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(nb.buf) then
          vim.api.nvim_buf_set_option(nb.buf, "modified", false)
        end
      end)
    end)
  end)
end

-- ---------- public API (called by keymaps) ----------

function M.run_cell(buf, opts)
  opts = opts or {}
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cell_id, range = nb:cell_at_line(lnum)
  if not cell_id then return end
  local cell = nb:get_cell(cell_id)
  -- Push current source to backend, then execute
  local cl = ensure_client()
  cl:call("update_cell_source", { session_id = nb.session_id, cell_id = cell.id, source = cell.source }, function(err)
    if err then
      vim.notify("update_cell_source: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    -- For markdown cells, just re-render
    if cell.cell_type == "markdown" then
      vim.schedule(function() Render.refresh(nb, vim.fn.bufwinid(buf)) end)
      if opts.advance then M.jump_cell(buf, 1) end
      return
    end
    cl:call("execute", { session_id = nb.session_id, cell_id = cell.id }, function(err2)
      if err2 then
        vim.notify("execute: " .. tostring(err2), vim.log.levels.ERROR)
      end
    end)
    if opts.advance then
      vim.schedule(function() M.jump_cell(buf, 1, true) end)
    end
  end)
end

function M.run_all(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  -- Sequence cells: each one's execute fires only after the previous update + execute have completed
  local cl = ensure_client()
  local code_cells = {}
  for _, c in ipairs(nb.cells) do
    if c.cell_type == "code" then table.insert(code_cells, c) end
  end
  local i = 1
  local function step()
    if i > #code_cells then return end
    local c = code_cells[i]; i = i + 1
    cl:call("update_cell_source", { session_id = nb.session_id, cell_id = c.id, source = c.source }, function()
      cl:call("execute", { session_id = nb.session_id, cell_id = c.id }, function()
        step()
      end)
    end)
  end
  step()
end

function M.run_above(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id = nb:cell_at_line(lnum)
  for _, c in ipairs(nb.cells) do
    if c.id == cur_id then break end
    if c.cell_type == "code" then
      local cl = ensure_client()
      cl:call("update_cell_source", { session_id = nb.session_id, cell_id = c.id, source = c.source }, function() end)
      cl:call("execute", { session_id = nb.session_id, cell_id = c.id }, function() end)
    end
  end
end

function M.run_below(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id = nb:cell_at_line(lnum)
  local seen = false
  for _, c in ipairs(nb.cells) do
    if c.id == cur_id then seen = true end
    if seen and c.cell_type == "code" then
      local cl = ensure_client()
      cl:call("update_cell_source", { session_id = nb.session_id, cell_id = c.id, source = c.source }, function() end)
      cl:call("execute", { session_id = nb.session_id, cell_id = c.id }, function() end)
    end
  end
end

function M.add_cell(buf, where)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id, range = nb:cell_at_line(lnum)
  local _, cur_idx = nb:get_cell(cur_id)
  local insert_at  -- 0-based after_index
  if where == "above" then
    insert_at = (cur_idx or 1) - 2  -- after the previous cell
    if insert_at < -1 then insert_at = -1 end
  else
    insert_at = (cur_idx or 1) - 1
  end

  local cl = ensure_client()
  cl:call("insert_cell", { session_id = nb.session_id, after_index = insert_at, cell_type = "code" }, function(err, res)
    if err then vim.notify("insert: " .. tostring(err), vim.log.levels.ERROR); return end
    -- Insert into local cells
    table.insert(nb.cells, insert_at + 2, { id = res.cell_id, cell_type = "code", source = "", outputs = {} })
    M._populate_buffer(nb)
    Render.refresh(nb, vim.fn.bufwinid(buf))
    -- Move cursor into the new cell
    local _, ranges = nb:to_lines()
    local r = ranges[insert_at + 2]
    if r then vim.api.nvim_win_set_cursor(vim.fn.bufwinid(buf), { r.start + 1, 0 }) end
  end)
end

function M.delete_cell(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id = nb:cell_at_line(lnum)
  if not cur_id then return end
  local cl = ensure_client()
  cl:call("delete_cell", { session_id = nb.session_id, cell_id = cur_id }, function(err)
    if err then vim.notify("delete: " .. tostring(err), vim.log.levels.ERROR); return end
    -- Remove locally
    for i, c in ipairs(nb.cells) do
      if c.id == cur_id then table.remove(nb.cells, i); break end
    end
    if #nb.cells == 0 then
      cl:call("insert_cell", { session_id = nb.session_id, after_index = -1, cell_type = "code" }, function(_, res)
        if res then table.insert(nb.cells, { id = res.cell_id, cell_type = "code", source = "", outputs = {} }) end
        M._populate_buffer(nb)
        Render.refresh(nb, vim.fn.bufwinid(buf))
      end)
    else
      M._populate_buffer(nb)
      Render.refresh(nb, vim.fn.bufwinid(buf))
    end
  end)
end

function M.move_cell(buf, delta)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id = nb:cell_at_line(lnum)
  if not cur_id then return end
  local cl = ensure_client()
  cl:call("move_cell", { session_id = nb.session_id, cell_id = cur_id, delta = delta }, function(err, res)
    if err then vim.notify("move: " .. tostring(err), vim.log.levels.ERROR); return end
    -- Apply locally
    local idx
    for i, c in ipairs(nb.cells) do if c.id == cur_id then idx = i; break end end
    if not idx then return end
    local new_idx = math.max(1, math.min(#nb.cells, idx + delta))
    local cell = table.remove(nb.cells, idx)
    table.insert(nb.cells, new_idx, cell)
    M._populate_buffer(nb)
    Render.refresh(nb, vim.fn.bufwinid(buf))
  end)
end

function M.set_cell_type(buf, t)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id = nb:cell_at_line(lnum)
  if not cur_id then return end
  local cl = ensure_client()
  cl:call("set_cell_type", { session_id = nb.session_id, cell_id = cur_id, cell_type = t }, function(err)
    if err then return end
    local cell = nb:get_cell(cur_id)
    if cell then
      cell.cell_type = t
      if t ~= "code" then cell.outputs = {}; cell.execution_count = nil end
    end
    Render.refresh(nb, vim.fn.bufwinid(buf))
  end)
end

function M.start_kernel(buf, kernel_name)
  local nb = Notebook.get(buf)
  if not nb then return end
  local cl = ensure_client()
  cl:call("start_kernel", { session_id = nb.session_id, kernel_name = kernel_name }, function(err, res)
    if err then
      vim.notify("start_kernel: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.notify("jupynvim: kernel '" .. (res.kernel_name or "?") .. "' started", vim.log.levels.INFO)
    -- Auto-inject inline plotting magic for python kernels (silent — no output)
    local lang = (nb.notebook_meta and nb.notebook_meta.language) or "python"
    if (res.kernel_name or ""):lower():find("python") or lang == "python" then
      cl:call("execute_silent", {
        session_id = nb.session_id,
        code = "try:\n    get_ipython().run_line_magic('matplotlib', 'inline')\nexcept Exception:\n    pass\n",
      }, function() end)
    end
    Render.refresh(nb, vim.fn.bufwinid(buf))
  end)
end

function M.stop_kernel(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  ensure_client():call("stop_kernel", { session_id = nb.session_id }, function() end)
end

function M.interrupt_kernel(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  ensure_client():call("interrupt_kernel", { session_id = nb.session_id }, function() end)
end

function M.restart_kernel(buf)
  local nb = Notebook.get(buf)
  if not nb then return end
  ensure_client():call("restart_kernel", { session_id = nb.session_id }, function(err, res)
    if err then vim.notify("restart: " .. tostring(err), vim.log.levels.ERROR); return end
    vim.notify("jupynvim: kernel restarted", vim.log.levels.INFO)
  end)
end

function M.kernel_picker(buf)
  ensure_client():call("list_kernels", {}, function(err, kernels)
    if err then vim.notify("list_kernels: " .. err, vim.log.levels.ERROR); return end
    vim.ui.select(kernels, {
      prompt = "Select kernel:",
      format_item = function(k) return k.display_name .. "  (" .. k.name .. ")" end,
    }, function(choice)
      if not choice then return end
      M.stop_kernel(buf)
      vim.defer_fn(function() M.start_kernel(buf, choice.name) end, 200)
    end)
  end)
end

-- Jump cursor to the next or previous cell that contains an image, either as
-- a markdown embedded image or a code-cell image output. delta > 0 moves
-- forward, delta < 0 moves backward.
function M.jump_image(buf, delta)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local _, ranges = nb:to_lines()
  if #ranges == 0 then return end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id = nb:cell_at_line(lnum)
  local cur_idx = 1
  for i, r in ipairs(ranges) do if r.id == cur_id then cur_idx = i; break end end

  local Embedded = require("jupynvim.embedded")
  local function has_image(cell)
    if cell.cell_type == "markdown" then
      local imgs = Embedded.list_images(cell.id) or {}
      if #imgs > 0 then return true end
    end
    for _, o in ipairs(cell.outputs or {}) do
      local d = (o.output_type == "execute_result" or o.output_type == "display_data") and o.data or nil
      if d and d["image/png"] then return true end
    end
    return false
  end

  local n = #ranges
  local step = delta >= 0 and 1 or -1
  for off = 1, n do
    local idx = cur_idx + off * step
    if idx < 1 or idx > n then break end
    local cell = nb.cells[idx]
    if cell and has_image(cell) then
      local r = ranges[idx]
      vim.api.nvim_win_set_cursor(0, { r.start + 1, 0 })
      return
    end
  end
  vim.notify("jupynvim: no " .. (delta >= 0 and "next" or "prev") .. " image cell",
    vim.log.levels.INFO)
end

function M.jump_cell(buf, delta, advance_to_end)
  local nb = Notebook.get(buf)
  if not nb then return end
  nb:sync_from_buffer()
  local _, ranges = nb:to_lines()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur_id, _, idx_at = nb:cell_at_line(lnum)
  -- find current index in ranges
  local cur_idx
  for i, r in ipairs(ranges) do if r.id == cur_id then cur_idx = i; break end end
  if not cur_idx then return end
  local target = cur_idx + delta
  if target < 1 then target = 1 end
  if target > #ranges then
    if advance_to_end then
      -- Insert a new cell below
      M.add_cell(buf, "below")
      return
    end
    target = #ranges
  end
  local r = ranges[target]
  if r then vim.api.nvim_win_set_cursor(0, { r.start + 1, 0 }) end
end

function M.refresh(buf)
  local nb = Notebook.get(buf)
  if nb then Render.refresh(nb, vim.fn.bufwinid(buf)) end
end

-- ---------- setup ----------

function M.setup(opts)
  M.config = vim.tbl_extend("force", M.config, opts or {})
  Log.set_level(M.config.log_level)
  Render.setup_highlights()

  vim.opt.conceallevel = 2
  vim.opt.concealcursor = "nc"

  -- Hijack .ipynb opens
  local group = vim.api.nvim_create_augroup("JupynvimDispatch", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = { "*.ipynb" },
    callback = function(args)
      -- BufReadCmd means user wants to read this file. If we already have a
      -- live notebook for it, treat as :e! (force reload from disk).
      local abs = vim.fn.fnamemodify(args.file, ":p")
      local b = vim.fn.bufnr(abs)
      local force = b > 0 and Notebook.get(b) ~= nil
      vim.schedule(function() M.open(args.file, { force = force }) end)
    end,
  })
  vim.api.nvim_create_autocmd("BufNewFile", {
    group = group,
    pattern = { "*.ipynb" },
    callback = function(args)
      -- New file: defer-create with empty notebook
      vim.schedule(function() M.open(args.file) end)
    end,
  })

  vim.api.nvim_create_user_command("JupynvimImageMode", function(o)
    local mode = o.args:match("^%s*(%S+)%s*$") or ""
    if mode ~= "chafa" and mode ~= "kitty" and mode ~= "placeholder" then
      vim.notify("Usage: :JupynvimImageMode chafa|kitty|placeholder", vim.log.levels.WARN)
      return
    end
    M.config.image_renderer = mode
    pcall(function() require("jupynvim.image").clear_all() end)
    for buf, nb in pairs(Notebook.all()) do
      nb.image_ids = {}
      Render.refresh(nb, vim.fn.bufwinid(buf))
    end
    vim.notify("jupynvim image_renderer = " .. mode, vim.log.levels.INFO)
  end, { nargs = 1, complete = function() return { "chafa", "kitty", "placeholder" } end })

  vim.api.nvim_create_user_command("JupynvimOpen", function(o) M.open(o.args) end, { nargs = 1, complete = "file" })
  vim.api.nvim_create_user_command("JupynvimRunCell", function() M.run_cell(0, { advance = false }) end, {})
  vim.api.nvim_create_user_command("JupynvimRunAll", function() M.run_all(0) end, {})
  vim.api.nvim_create_user_command("JupynvimKernel", function() M.kernel_picker(0) end, {})
  vim.api.nvim_create_user_command("JupynvimRestart", function() M.restart_kernel(0) end, {})

  -- Nuclear reset: close all sessions, wipe all notebook buffers, reload from disk.
  vim.api.nvim_create_user_command("JupynvimReset", function()
    for buf, nb in pairs(Notebook.all()) do
      if nb.session_id and M.client then
        M.client:call("close", { session_id = nb.session_id }, function() end)
      end
      Notebook.remove(buf)
      pcall(Image.clear_all)
      if vim.api.nvim_buf_is_valid(buf) then
        local path = vim.api.nvim_buf_get_name(buf)
        vim.api.nvim_buf_delete(buf, { force = true })
        if path:match("%.ipynb$") then
          vim.defer_fn(function() M.open(path, { force = true }) end, 100)
        end
      end
    end
    vim.notify("jupynvim: reset complete", vim.log.levels.INFO)
  end, {})

  -- Diagnostic: print the current state of the notebook buffer.
  vim.api.nvim_create_user_command("JupynvimDebug", function()
    local buf = vim.api.nvim_get_current_buf()
    local nb = Notebook.get(buf)
    if not nb then
      print("no notebook for buffer " .. buf)
      return
    end
    print(string.format("buf=%d session=%s path=%s", buf, nb.session_id:sub(1,8), nb.path))
    print(string.format("buffer line count: %d", vim.api.nvim_buf_line_count(buf)))
    print(string.format("nb.cells count:    %d", #nb.cells))
    -- Window dup detection — if more than one window shows this buffer, the user
    -- is seeing apparent "duplicate cells" because both windows render the same buffer.
    local wins = vim.fn.win_findbuf(buf)
    print(string.format("windows showing this buf: %d  (Ctrl-w o to close others)", #wins))
    for i, c in ipairs(nb.cells) do
      print(string.format("  [%d] id=%s type=%s ec=%s outs=%d", i, c.id, c.cell_type, tostring(c.execution_count), #(c.outputs or {})))
    end
    print(string.format("image.supported: %s", tostring(Image.supported())))
    print(string.format("image_ids: %s", vim.inspect(nb.image_ids or {})))
    print(string.format("placements: %s", vim.inspect(Image._placements or {})))
  end, {})
end

return M
