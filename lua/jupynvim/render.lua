-- Render a Notebook into its buffer using extmarks.
--
-- Visual layout per cell:
--   ╭─ [3] Code ──────── (idle)
--   <cell source line 1>
--   <cell source line 2>
--   ├─ Out[3] ──────────
--   <output text as virt_lines>
--   <inline image placement>
--   ╰────────────────────
--
-- Implementation:
--   • One extmark per cell on its first line:
--       virt_lines_above = header
--       (separate extmark for footer/outputs anchored to last line)
--   • One extmark on each separator line: hide the "# %%" via virt_text replacement
--   • Output extmarks store images via Kitty graphics protocol (image.lua)

local Notebook = require("jupynvim.notebook")
local image = require("jupynvim.image")
local log = require("jupynvim.log")

local M = {}

-- Highlight groups (defined in init)
local HL_BORDER  = "JupynvimBorder"
local HL_HEADER  = "JupynvimCellHeader"
local HL_BUSY    = "JupynvimBusy"
local HL_OUTPUT  = "JupynvimOutput"
local HL_ERROR   = "JupynvimError"
local HL_STREAM  = "JupynvimStream"
local HL_RESULT  = "JupynvimResult"
local HL_MARKDOWN = "JupynvimMarkdown"

local function repeat_char(ch, n)
  if n <= 0 then return "" end
  return string.rep(ch, n)
end

local function dw(s) return vim.fn.strdisplaywidth(s) end

-- Closed box drawing — top/bottom/divider virt_lines start with ┌/└/├ and
-- end with ┐/┘/┤. Each source line gets `│ ` inline at col 0 and `│`
-- right_align so the corners VISUALLY connect with the side bars.
local function header_line(width, badge, label, state)
  local mid_state = state and (" (" .. state .. ")") or ""
  local main = "┌─ [" .. badge .. "] " .. label .. mid_state .. " "
  local pad = width - dw(main) - 1
  return main .. repeat_char("─", math.max(pad, 0)) .. "┐"
end

local function footer_line(width)
  return "└" .. repeat_char("─", math.max(width - 2, 0)) .. "┘"
end

local function divider_line(width, label)
  local main = "├─ " .. label .. " "
  local pad = width - dw(main) - 1
  return main .. repeat_char("─", math.max(pad, 0)) .. "┤"
end

-- Wrap a single line to `width` DISPLAY COLUMNS, breaking at space
-- boundaries when possible so words don't split mid-character. Falls back
-- to a hard char break for runs longer than `width` with no whitespace.
-- Uses display widths (not byte lengths) so multi-byte UTF-8 stays intact.
local function wrap(line, width)
  if width <= 0 then return { line } end
  if vim.fn.strdisplaywidth(line) <= width then return { line } end
  local out = {}
  local n = vim.fn.strchars(line)
  local pos = 0
  while pos < n do
    local start = pos
    local cur_w = 0
    local last_space = -1
    while pos < n do
      local ch = vim.fn.strcharpart(line, pos, 1)
      local cw = vim.fn.strdisplaywidth(ch)
      if cur_w + cw > width then break end
      if ch == " " then last_space = pos end
      cur_w = cur_w + cw
      pos = pos + 1
    end
    if pos < n and last_space > start then
      table.insert(out, vim.fn.strcharpart(line, start, last_space - start))
      pos = last_space + 1
    else
      if pos == start then pos = pos + 1 end
      table.insert(out, vim.fn.strcharpart(line, start, pos - start))
    end
  end
  return out
end

-- Build the virt_lines for a cell's outputs.
--
-- For images, instead of reserving blank lines, we produce Kitty Unicode
-- placeholder rows. These are emitted as virt_lines and the terminal renders
-- the image where the placeholders are.
--
-- The image_id is fetched lazily via image.ensure_transmitted; until ready,
-- a "loading…" placeholder is shown.
-- Wrap inner content with the box sides: "│ <content padded to width-3> │"
local function with_sides(text, hl, width)
  local inner = dw(text)
  -- If text is somehow wider than the cell box, truncate to keep borders intact
  if inner > width - 4 then
    text = vim.fn.strcharpart(text, 0, math.max(width - 5, 1))
    inner = dw(text)
  end
  local pad = math.max(width - 4 - inner, 0)
  return {
    { "│ ", HL_BORDER },
    { text, hl },
    { string.rep(" ", pad) .. " │", HL_BORDER },
  }
end

-- nbformat stores text fields as either a single string or an array of
-- strings (lines). Normalize to one string.
local function as_str(v)
  if type(v) == "table" then return table.concat(v, "") end
  if type(v) == "string" then return v end
  return ""
end

-- Strip ANSI escape sequences (SGR colors, cursor moves, etc.).
local function strip_ansi(s)
  s = s:gsub("\27%[[?]?[%d;]*[a-zA-Z]", "")
  s = s:gsub("\27%][^\27]*\27\\", "")
  s = s:gsub("\27.", "")
  return s
end

-- Apply tqdm/progress-bar carriage-return semantics: \r OVERWRITES the
-- current line. Each \r-terminated chunk is replaced; only the LAST chunk
-- per logical line is kept. Then split by real newlines.
local function process_cr(s)
  local out = {}
  for chunk in (s .. "\n"):gmatch("([^\n]*)\n") do
    local segments = {}
    for seg in (chunk .. "\r"):gmatch("([^\r]*)\r") do
      table.insert(segments, seg)
    end
    table.insert(out, segments[#segments] or "")
  end
  if out[#out] == "" then table.remove(out) end
  return table.concat(out, "\n")
end

-- Compact a tqdm progress bar: shorten the long block-char run.
-- Matches `[NUM]%|<bar>| ...` patterns.
local function compact_tqdm(line)
  -- Pattern: optional spaces, NUM%, |, blocks/spaces, |, rest
  local prefix, bar, rest = line:match("^(%s*%d+%%)|(.-)|(.*)$")
  if not prefix or not bar then return line end
  -- If bar contains tqdm block chars, shorten to a fixed display
  if bar:match("[█▏▎▍▌▋▊▉ ]") then
    local short = "███████████████"  -- fixed 15-cell bar
    return prefix .. "|" .. short .. "|" .. rest
  end
  return line
end

local function build_output_virt_lines(cell, width, nb)
  local rows = {}
  for _, o in ipairs(cell.outputs or {}) do
    if o.output_type == "stream" then
      -- stderr is rendered in subdued gray (HL_OUTPUT) instead of bright red
      -- so tqdm/wandb output (most common stderr) doesn't visually scream.
      local hl = (o.name == "stderr") and HL_OUTPUT or HL_STREAM
      local text = strip_ansi(process_cr(as_str(o.text)))
      for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
        line = compact_tqdm(line)
        for _, w in ipairs(wrap(line, width - 4)) do
          table.insert(rows, with_sides(w, hl, width))
        end
      end
    elseif o.output_type == "execute_result" or o.output_type == "display_data" then
      local data = o.data or {}
      local has_img = (data["image/png"] ~= nil)
      local text = as_str(data["text/plain"])
      -- Hide the boring matplotlib `<Figure size NxM with K Axes>` repr when
      -- the actual image is rendered alongside.
      if has_img and (text == "" or text:match("^<[Ff]igure ")) then
        text = ""
      end
      -- If text/plain is just the boring object repr, try extracting visible
      -- text from text/html (used by wandb, tqdm widgets, etc.)
      if text == "" or text:match("^<[A-Za-z._]+ object>$") then
        local html = as_str(data["text/html"])
        if html ~= "" then
          -- Strip tags, preserve text and href attributes for links
          local plain = html
            :gsub("<a[^>]*href=\"([^\"]*)\"[^>]*>(.-)</a>", "%2 (%1)")
            :gsub("<br%s*/?>", "\n")
            :gsub("</p>", "\n")
            :gsub("<[^>]+>", "")
            :gsub("&nbsp;", " ")
            :gsub("&amp;", "&")
            :gsub("&lt;", "<")
            :gsub("&gt;", ">")
            :gsub("&#x?%w+;", "")
            :gsub("\n\n+", "\n")
          text = plain:gsub("^%s+", ""):gsub("%s+$", "")
        end
      end
      if text ~= "" then
        for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
          for _, w in ipairs(wrap(line, width - 4)) do
            table.insert(rows, with_sides(w, HL_RESULT, width))
          end
        end
      end
      local b64 = data["image/png"]
      if type(b64) == "table" then b64 = table.concat(b64, "") end
      if type(b64) == "string" and b64 ~= "" then
        local ph = image.placeholder_virt_lines(cell.id)
        if ph then
          local cols = image.placement_cols(cell.id) or 56
          for _, line in ipairs(ph) do
            local inner_text = line[1][1]
            local inner_hl = line[1][2]
            local pad = math.max(width - 4 - cols, 0)
            table.insert(rows, {
              { "│ ", HL_BORDER },
              { inner_text, inner_hl },
              { string.rep(" ", pad) .. " │", HL_BORDER },
            })
          end
        else
          local ascii = image.ascii_lines_for(cell.id)
          if ascii then
            for _, line in ipairs(ascii) do
              table.insert(rows, with_sides(line, "Normal", width))
            end
          elseif image.supported() then
            for _ = 1, 14 do
              table.insert(rows, with_sides(string.rep(" ", math.max(width - 4, 0)), HL_OUTPUT, width))
            end
          end
        end
      end
    elseif o.output_type == "error" then
      local msg = as_str(o.ename) .. ": " .. as_str(o.evalue)
      if msg == ": " then msg = "Error" end
      for _, w in ipairs(wrap(msg, width - 4)) do
        table.insert(rows, with_sides(w, HL_ERROR, width))
      end
      for _, tb in ipairs(o.traceback or {}) do
        local plain = as_str(tb):gsub("\27%[[%d;]*m", "")
        for _, line in ipairs(vim.split(plain, "\n", { plain = true })) do
          for _, w in ipairs(wrap(line, width - 4)) do
            table.insert(rows, with_sides(w, HL_ERROR, width))
          end
        end
      end
    end
  end
  return rows
end

-- Render a single cell. Returns the number of image lines we reserved (for image placement).
local function render_cell(nb, cell, range, width, win)
  local buf = nb.buf
  -- Normalize execution_count: vim.NIL or nil → blank
  local ec_raw = cell.execution_count
  if ec_raw == vim.NIL or ec_raw == nil then ec_raw = nil end
  local exec = ec_raw and tostring(ec_raw) or " "
  local state = nb.cell_state[cell.id] and nb.cell_state[cell.id].exec_state
  local badge
  if state == "busy" then badge = "*" else badge = exec end

  local label
  if cell.cell_type == "code" then
    label = "Code"
  elseif cell.cell_type == "markdown" then
    label = "Markdown"
    badge = " "  -- markdown has no exec count
  else
    label = cell.cell_type or "Cell"
    badge = " "
  end

  local total = vim.api.nvim_buf_line_count(buf)
  if range.start >= total then return end -- buffer shorter than expected; skip safely

  local hdr = header_line(width, badge, label, state == "busy" and "running" or nil)
  vim.api.nvim_buf_set_extmark(buf, nb.border_ns, range.start, 0, {
    virt_lines = { { { hdr, state == "busy" and HL_BUSY or HL_HEADER } } },
    virt_lines_above = true,
  })

  -- Output region under the cell's last line
  local lines_below = {}
  if cell.cell_type == "code" then
    local has_outputs = #(cell.outputs or {}) > 0
    if has_outputs then
      table.insert(lines_below, { { divider_line(width, "Out[" .. (ec_raw or " ") .. "]"), HL_HEADER } })
      for _, l in ipairs(build_output_virt_lines(cell, width, nb)) do
        table.insert(lines_below, l)
      end
    end
    table.insert(lines_below, { { footer_line(width), HL_BORDER } })
  elseif cell.cell_type == "markdown" then
    -- Render embedded markdown images (placeholder mode supported)
    local Embedded = require("jupynvim.embedded")
    local imgs = Embedded.list_images(cell.id) or {}
    for _, img in ipairs(imgs) do
      local key = cell.id .. "_md_" .. img.idx
      local ph = image.placeholder_virt_lines(key)
      if ph then
        local cols = image.placement_cols(key) or 56
        for _, line in ipairs(ph) do
          local inner_text = line[1][1]
          local inner_hl = line[1][2]
          local pad = math.max(width - 4 - cols, 0)
          table.insert(lines_below, {
            { "│ ", HL_BORDER },
            { inner_text, inner_hl },
            { string.rep(" ", pad) .. " │", HL_BORDER },
          })
        end
      else
        local ascii = image.ascii_lines_for(key)
        if ascii then
          for _, line in ipairs(ascii) do
            table.insert(lines_below, with_sides(line, "Normal", width))
          end
        end
      end
    end
    table.insert(lines_below, { { footer_line(width), HL_BORDER } })
  else
    table.insert(lines_below, { { footer_line(width), HL_BORDER } })
  end

  local last = math.max(range.stop - 1, range.start)
  if last >= total then last = total - 1 end
  if last < 0 then return end
  vim.api.nvim_buf_set_extmark(buf, nb.border_ns, last, 0, {
    virt_lines = lines_below,
  })

  -- Both borders live in the text area at fixed columns so they line up
  -- with the ┌ ┐ ├ ┤ └ ┘ glyphs in the header, divider, and footer
  -- (all at columns 0 and width-1).
  --
  -- For wrapped lines neovim only renders virt_text_win_col on the first
  -- visual row, leaving continuation rows with no right bar. Stacking a
  -- second mark with right_align at a lower priority adds a bar on the
  -- last visual row too. Lower priority avoids doubling on unwrapped
  -- lines where both marks land at the same column. lines wrapping to
  -- two visual rows now get a bar on both rows. Three or more rows still
  -- have a gap on the middle rows.
  for ln = range.start, math.min(range.stop - 1, total - 1) do
    pcall(vim.api.nvim_buf_set_extmark, buf, nb.border_ns, ln, 0, {
      virt_text = { { "│ ", HL_BORDER } },
      virt_text_pos = "inline",
      hl_mode = "combine",
      priority = 100,
    })
    pcall(vim.api.nvim_buf_set_extmark, buf, nb.border_ns, ln, 0, {
      virt_text = { { "│", HL_BORDER } },
      virt_text_win_col = width - 1,
      hl_mode = "combine",
      priority = 100,
    })
    pcall(vim.api.nvim_buf_set_extmark, buf, nb.border_ns, ln, 0, {
      virt_text = { { "│", HL_BORDER } },
      virt_text_pos = "right_align",
      hl_mode = "combine",
      priority = 50,
    })
  end

  -- Markdown cells: render styling + transmit embedded images
  if cell.cell_type == "markdown" then
    require("jupynvim.markdown").render(buf, nb.border_ns,
      range.start, math.min(range.stop - 1, total - 1), width)
    local Embedded = require("jupynvim.embedded")
    local imgs = Embedded.list_images(cell.id)
    if imgs and #imgs > 0 then
      nb.image_ids = nb.image_ids or {}
      for _, img in ipairs(imgs) do
        local key = cell.id .. "_md_" .. img.idx
        local renderer = (require("jupynvim").config.image_renderer) or "chafa"
        if not nb.image_ids[key] then
          image.ensure_transmitted(key, img.b64, function(id)
            if id then
              nb.image_ids[key] = id
              vim.schedule(function() M.refresh(nb, win) end)
            end
          end, { renderer = renderer, mime = img.mime })
        end
      end
    end
  end

  -- Schedule image placements for image outputs
  if cell.cell_type == "code" and image.supported() then
    M.place_images(nb, cell, range, win)
  end
end

-- For each image/png in a cell's outputs, register the image_id and place it
-- directly at the correct screen row using Kitty's a=T (transmit-and-place).
-- This bypasses Unicode placeholder support which is incomplete in Ghostty 1.3.
function M.place_images(nb, cell, range, win)
  nb.image_ids = nb.image_ids or {}
  local b64
  for _, o in ipairs(cell.outputs or {}) do
    if (o.output_type == "execute_result" or o.output_type == "display_data") then
      local d = o.data or {}
      local v = d["image/png"]
      if type(v) == "table" then v = table.concat(v, "") end
      if type(v) == "string" and v ~= "" then
        b64 = v
        break
      end
    end
  end
  if not b64 then
    image.clear_for_cell(cell.id)
    nb.image_ids[cell.id] = nil
    return
  end
  local renderer = (require("jupynvim").config.image_renderer) or "chafa"
  -- Track if cache was already populated for this cell with this renderer
  local was_cached = (image._placements and image._placements[cell.id]
    and image._placements[cell.id].renderer == renderer)
  image.ensure_transmitted(cell.id, b64, function(id)
    if not id then return end
    nb.image_ids[cell.id] = id
    if renderer == "kitty" then
      vim.schedule(function()
        if not win or not vim.api.nvim_win_is_valid(win) then
          win = vim.fn.bufwinid(nb.buf)
        end
        if not win or win == -1 then return end
        local anchor_lnum = math.min(range.stop, vim.api.nvim_buf_line_count(nb.buf))
        local pos = vim.fn.screenpos(win, anchor_lnum, 1)
        if pos and pos.row and pos.row > 0 then
          local img_row = pos.row + 2
          local img_col = 5
          image.place_at_screen_row(cell.id, img_row, img_col, 14, 56)
        end
      end)
    end
    -- If the cache was just populated (or replaced), schedule another
    -- render so build_output_virt_lines picks up the new placement.
    if not was_cached then
      vim.schedule(function() M.refresh(nb, win) end)
    end
  end, { renderer = renderer })
end

local function clear_separators(nb, ranges)
  local buf = nb.buf
  local total = vim.api.nvim_buf_line_count(buf)
  for i = 1, #ranges - 1 do
    local sep_line = ranges[i].stop
    if sep_line < total then
      local line_text = vim.api.nvim_buf_get_lines(buf, sep_line, sep_line + 1, false)[1] or ""
      -- Conceal the ENTIRE separator line (not just first few chars)
      vim.api.nvim_buf_set_extmark(buf, nb.border_ns, sep_line, 0, {
        end_col = #line_text,
        conceal = "",
        priority = 200,
      })
      -- Show a thin "····" decoration as overlay
      vim.api.nvim_buf_set_extmark(buf, nb.border_ns, sep_line, 0, {
        virt_text = { { "····", "JupynvimSeparator" } },
        virt_text_pos = "overlay",
        hl_mode = "combine",
        priority = 199,
      })
    end
  end
end

-- Refresh is debounced and serialized to avoid concurrent renders racing
-- (which produces stacked phantom extmarks).
local _refresh_pending = {}  -- buf -> true
function M.refresh(nb, win)
  local buf = nb.buf
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if _refresh_pending[buf] then return end
  _refresh_pending[buf] = true
  vim.schedule(function()
    _refresh_pending[buf] = nil
    if not vim.api.nvim_buf_is_valid(buf) then return end

    vim.api.nvim_buf_clear_namespace(buf, nb.border_ns, 0, -1)

    -- Compute cell ranges DIRECTLY from buffer text — so newly typed lines
    -- are picked up immediately without waiting for sync_from_buffer.
    local Notebook = require("jupynvim.notebook")
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local ranges = {}
    local cur_start = 0
    local cell_idx = 1
    for i, line in ipairs(lines) do
      if line == Notebook.CELL_SEP then
        table.insert(ranges, { start = cur_start, stop = i - 1, idx = cell_idx })
        cell_idx = cell_idx + 1
        cur_start = i
      end
    end
    table.insert(ranges, { start = cur_start, stop = #lines, idx = cell_idx })
    -- Compute text-area width by reading the actual window options.
    -- Fall back to ANY visible window for this buffer, then current win.
    if not win or not vim.api.nvim_win_is_valid(win) then
      local wins = vim.fn.win_findbuf(buf)
      win = (wins and wins[1]) or vim.api.nvim_get_current_win()
    end
    local width = 80
    if win and vim.api.nvim_win_is_valid(win) then
      local total = vim.api.nvim_win_get_width(win)
      -- signcolumn: yes:N or auto:N → 2*N cells; yes/auto → 2 cells
      local sc = vim.api.nvim_get_option_value("signcolumn", { win = win })
      local sc_w = 0
      local m = sc:match("^yes:(%d+)$") or sc:match("^auto:(%d+)$")
      if m then sc_w = 2 * tonumber(m)
      elseif sc == "yes" or sc == "auto" then sc_w = 2 end
      -- numbercolumn. numberwidth is the MINIMUM; the actual displayed
      -- column auto-expands to fit the largest line number plus one
      -- trailing space. for a 1014-line buffer the actual is 5 even
      -- though numberwidth is 4. using numberwidth directly puts the
      -- right border one cell past the visible window edge.
      local has_num = vim.api.nvim_get_option_value("number", { win = win })
      local has_rnum = vim.api.nvim_get_option_value("relativenumber", { win = win })
      local nu_w = 0
      if has_num or has_rnum then
        local nuw_opt = vim.api.nvim_get_option_value("numberwidth", { win = win })
        local min_nuw = (type(nuw_opt) == "number") and nuw_opt or 4
        local digits = #tostring(vim.api.nvim_buf_line_count(buf))
        nu_w = math.max(min_nuw, digits + 1)
      end
      -- foldcolumn
      local fc = vim.api.nvim_get_option_value("foldcolumn", { win = win })
      local fc_w = tonumber(fc) or 0
      width = math.max(total - sc_w - nu_w - fc_w, 40)
    end

    for i, r in ipairs(ranges) do
      local cell = nb.cells[i]
      if cell then
        local ok, err = pcall(render_cell, nb, cell, r, width, win)
        if not ok then
          require("jupynvim.log").warn("render_cell failed for cell " .. tostring(i) .. ": " .. tostring(err))
        end
      end
    end
    clear_separators(nb, ranges)
  end)
end

function M.setup_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, HL_BORDER,    { fg = "#7aa2f7" })
  hl(0, HL_HEADER,    { fg = "#7aa2f7", bold = true })
  hl(0, HL_BUSY,      { fg = "#e0af68", bold = true })
  hl(0, HL_OUTPUT,    { fg = "#a9b1d6" })
  hl(0, HL_ERROR,     { fg = "#f7768e", bold = true })
  hl(0, HL_STREAM,    { fg = "#9ece6a" })
  hl(0, HL_RESULT,    { fg = "#bb9af7" })
  hl(0, HL_MARKDOWN,  { bg = "#1a1b26" })
  hl(0, "JupynvimCellBg", { bg = "#16161e" })
  hl(0, "JupynvimSeparator", { fg = "#414868" })
  -- Define the sign used for the left cell-border bar.
  pcall(vim.fn.sign_define, "JupynvimBar", { text = "│", texthl = HL_BORDER })
  require("jupynvim.markdown").setup_hl()
end

return M
