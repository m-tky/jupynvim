-- VSCode-style rendering for markdown cells.
--
-- We don't actually rewrite the buffer; instead we use extmarks with
-- `conceal` and `virt_text` to make markdown source LOOK like rendered
-- markdown — headings get larger/bolder fg, list bullets get glyphs,
-- inline code/bold/italic get their markers concealed and styled.
--
-- Reference: https://neovim.io/doc/user/api.html#nvim_buf_set_extmark()

local M = {}

-- Highlight groups (defined in setup_hl)
local HL = {
  H1   = "JupynvimMdH1",
  H2   = "JupynvimMdH2",
  H3   = "JupynvimMdH3",
  H4   = "JupynvimMdH4",
  H5   = "JupynvimMdH5",
  H6   = "JupynvimMdH6",
  Bold = "JupynvimMdBold",
  Em   = "JupynvimMdEm",
  Code = "JupynvimMdCode",
  Link = "JupynvimMdLink",
  Quote = "JupynvimMdQuote",
  Bullet = "JupynvimMdBullet",
  HR    = "JupynvimMdHR",
  Math  = "JupynvimMdMath",
  MathBlock = "JupynvimMdMathBlock",
}

function M.setup_hl()
  local hl = vim.api.nvim_set_hl
  -- VSCode-notebook style: bold colored heading text, NO background fill.
  hl(0, HL.H1,   { fg = "#7aa2f7", bold = true })
  hl(0, HL.H2,   { fg = "#bb9af7", bold = true })
  hl(0, HL.H3,   { fg = "#9ece6a", bold = true })
  hl(0, HL.H4,   { fg = "#e0af68", bold = true })
  hl(0, HL.H5,   { fg = "#7dcfff", bold = true })
  hl(0, HL.H6,   { fg = "#a9b1d6", bold = true })
  hl(0, HL.Bold, { bold = true, fg = "#c0caf5" })
  hl(0, HL.Em,   { italic = true, fg = "#c0caf5" })
  hl(0, HL.Code, { fg = "#9ece6a", bg = "#1f2335" })
  hl(0, HL.Link, { fg = "#7dcfff", underline = true })
  hl(0, HL.Quote, { fg = "#737aa2", italic = true })
  hl(0, HL.Bullet, { fg = "#7aa2f7", bold = true })
  hl(0, HL.HR,   { fg = "#414868" })
  hl(0, HL.Math, { fg = "#7dcfff", italic = true })
  hl(0, HL.MathBlock, { fg = "#7dcfff", bold = true, bg = "#1f2335" })
end

-- Replace common LaTeX commands with Unicode equivalents for visual rendering.
-- Keeps the original buffer text unchanged — used only for virt_text overlays.
local LATEX_SYMBOLS = {
  ["\\int"] = "∫", ["\\sum"] = "∑", ["\\prod"] = "∏",
  ["\\infty"] = "∞", ["\\partial"] = "∂", ["\\nabla"] = "∇",
  ["\\alpha"] = "α", ["\\beta"] = "β", ["\\gamma"] = "γ",
  ["\\delta"] = "δ", ["\\epsilon"] = "ε", ["\\zeta"] = "ζ",
  ["\\eta"] = "η", ["\\theta"] = "θ", ["\\iota"] = "ι",
  ["\\kappa"] = "κ", ["\\lambda"] = "λ", ["\\mu"] = "μ",
  ["\\nu"] = "ν", ["\\xi"] = "ξ", ["\\pi"] = "π",
  ["\\rho"] = "ρ", ["\\sigma"] = "σ", ["\\tau"] = "τ",
  ["\\phi"] = "φ", ["\\chi"] = "χ", ["\\psi"] = "ψ", ["\\omega"] = "ω",
  ["\\Gamma"] = "Γ", ["\\Delta"] = "Δ", ["\\Theta"] = "Θ",
  ["\\Lambda"] = "Λ", ["\\Xi"] = "Ξ", ["\\Pi"] = "Π",
  ["\\Sigma"] = "Σ", ["\\Phi"] = "Φ", ["\\Psi"] = "Ψ", ["\\Omega"] = "Ω",
  ["\\leq"] = "≤", ["\\geq"] = "≥", ["\\neq"] = "≠",
  ["\\approx"] = "≈", ["\\equiv"] = "≡", ["\\sim"] = "∼",
  ["\\pm"] = "±", ["\\mp"] = "∓", ["\\times"] = "×", ["\\div"] = "÷",
  ["\\cdot"] = "·", ["\\circ"] = "∘", ["\\bullet"] = "•",
  ["\\rightarrow"] = "→", ["\\leftarrow"] = "←", ["\\Rightarrow"] = "⇒",
  ["\\Leftarrow"] = "⇐", ["\\Leftrightarrow"] = "⇔",
  ["\\sqrt"] = "√", ["\\forall"] = "∀", ["\\exists"] = "∃",
  ["\\in"] = "∈", ["\\notin"] = "∉", ["\\subset"] = "⊂", ["\\supset"] = "⊃",
  ["\\cup"] = "∪", ["\\cap"] = "∩", ["\\emptyset"] = "∅",
  ["\\,"] = " ", ["\\;"] = " ", ["\\:"] = " ", ["\\!"] = "",
}

local SUPER = {
  ["0"]="⁰", ["1"]="¹", ["2"]="²", ["3"]="³", ["4"]="⁴",
  ["5"]="⁵", ["6"]="⁶", ["7"]="⁷", ["8"]="⁸", ["9"]="⁹",
  ["+"]="⁺", ["-"]="⁻", ["="]="⁼", ["("]="⁽", [")"]="⁾",
  ["a"]="ᵃ", ["b"]="ᵇ", ["c"]="ᶜ", ["d"]="ᵈ", ["e"]="ᵉ",
  ["f"]="ᶠ", ["g"]="ᵍ", ["h"]="ʰ", ["i"]="ⁱ", ["j"]="ʲ",
  ["k"]="ᵏ", ["l"]="ˡ", ["m"]="ᵐ", ["n"]="ⁿ", ["o"]="ᵒ",
  ["p"]="ᵖ", ["r"]="ʳ", ["s"]="ˢ", ["t"]="ᵗ", ["u"]="ᵘ",
  ["v"]="ᵛ", ["w"]="ʷ", ["x"]="ˣ", ["y"]="ʸ", ["z"]="ᶻ",
}
local SUB = {
  ["0"]="₀", ["1"]="₁", ["2"]="₂", ["3"]="₃", ["4"]="₄",
  ["5"]="₅", ["6"]="₆", ["7"]="₇", ["8"]="₈", ["9"]="₉",
  ["+"]="₊", ["-"]="₋", ["="]="₌", ["("]="₍", [")"]="₎",
  ["a"]="ₐ", ["e"]="ₑ", ["h"]="ₕ", ["i"]="ᵢ", ["j"]="ⱼ",
  ["k"]="ₖ", ["l"]="ₗ", ["m"]="ₘ", ["n"]="ₙ", ["o"]="ₒ",
  ["p"]="ₚ", ["r"]="ᵣ", ["s"]="ₛ", ["t"]="ₜ", ["u"]="ᵤ",
  ["v"]="ᵥ", ["x"]="ₓ",
}

-- Sort LaTeX command keys by length descending so longer commands match before
-- shorter prefixes (e.g. \int before \in, \sigma before \sin).
local _LATEX_ORDERED = nil
local function ordered_latex()
  if _LATEX_ORDERED then return _LATEX_ORDERED end
  _LATEX_ORDERED = {}
  for k, v in pairs(LATEX_SYMBOLS) do
    table.insert(_LATEX_ORDERED, { k, v })
  end
  table.sort(_LATEX_ORDERED, function(a, b) return #a[1] > #b[1] end)
  return _LATEX_ORDERED
end

local function unicodify_math(s)
  local out = s
  -- LaTeX commands, longest first
  for _, kv in ipairs(ordered_latex()) do
    local cmd, sym = kv[1], kv[2]
    out = out:gsub(cmd:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"), sym)
  end
  -- ^N (single char)
  out = out:gsub("%^(%w)", function(c) return SUPER[c] or ("^" .. c) end)
  out = out:gsub("%^{([^}]+)}", function(s)
    local r = ""; for ch in s:gmatch(".") do r = r .. (SUPER[ch] or ch) end; return r
  end)
  -- _N
  out = out:gsub("_(%w)", function(c) return SUB[c] or ("_" .. c) end)
  out = out:gsub("_{([^}]+)}", function(s)
    local r = ""; for ch in s:gmatch(".") do r = r .. (SUB[ch] or ch) end; return r
  end)
  -- \frac{a}{b} → a/b
  out = out:gsub("\\frac%s*{([^}]+)}%s*{([^}]+)}", "%1⁄%2")
  return out
end
M._unicodify_math = unicodify_math

-- ---------- helpers (must be declared before any caller) ----------

local function set_mark(buf, ns, lnum, col, opts)
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum, col, opts)
end

local function conceal_range(buf, ns, lnum, start_col, end_col, char)
  set_mark(buf, ns, lnum, start_col, {
    end_col = end_col,
    conceal = char or "",
    hl_mode = "combine",
    priority = 200,
  })
end

local function inline_styling(buf, ns, lnum, line)
  -- Bold **text**
  local s = 1
  while true do
    local a, b = line:find("%*%*[^%*]+%*%*", s)
    if not a then break end
    conceal_range(buf, ns, lnum, a - 1, a + 1, "")
    set_mark(buf, ns, lnum, a + 1, { end_col = b - 2, hl_group = HL.Bold, hl_mode = "combine" })
    conceal_range(buf, ns, lnum, b - 2, b, "")
    s = b + 1
  end
  -- Italic *text* (single asterisks; require non-* neighbours to avoid bold/list overlap)
  s = 1
  while true do
    local a, b = line:find("([^%*])%*([^%*\n][^%*\n]-)%*", s)
    if not a then break end
    local star1 = a + 1
    local inner_end = b
    conceal_range(buf, ns, lnum, star1 - 1, star1, "")
    set_mark(buf, ns, lnum, star1, { end_col = inner_end - 1, hl_group = HL.Em, hl_mode = "combine" })
    conceal_range(buf, ns, lnum, inner_end - 1, inner_end, "")
    s = b + 1
  end
  -- Inline code `text`
  s = 1
  while true do
    local a, b = line:find("`([^`]+)`", s)
    if not a then break end
    conceal_range(buf, ns, lnum, a - 1, a, "")
    set_mark(buf, ns, lnum, a, { end_col = b - 1, hl_group = HL.Code, hl_mode = "combine" })
    conceal_range(buf, ns, lnum, b - 1, b, "")
    s = b + 1
  end
  -- Inline math $...$ — replace with Unicode-rendered version
  s = 1
  while true do
    local a, b = line:find("%$[^%$\n]+%$", s)
    if not a then break end
    local prev = a > 1 and line:sub(a - 1, a - 1) or ""
    local next_ = line:sub(b + 1, b + 1)
    if prev ~= "$" and next_ ~= "$" then
      local raw_inner = line:sub(a + 1, b - 1)
      local pretty = unicodify_math(raw_inner)
      -- Replace whole $...$ span with the unicode-rendered text
      set_mark(buf, ns, lnum, a - 1, {
        end_col = b,
        conceal = "",
        virt_text = { { pretty, HL.Math } },
        virt_text_pos = "inline",
        hl_mode = "combine",
        priority = 105,
      })
    end
    s = b + 1
  end
  -- Links [text](url)
  s = 1
  while true do
    local a, b = line:find("(%[)([^%]]+)(%]%()[^%)]+(%))", s)
    if not a then break end
    local text_open = a
    local text_close = a + #line:sub(a, b):match("^%[[^%]]+%]") - 1
    local link_close = b
    conceal_range(buf, ns, lnum, text_open - 1, text_open, "")
    set_mark(buf, ns, lnum, text_open, { end_col = text_close - 1, hl_group = HL.Link, hl_mode = "combine" })
    conceal_range(buf, ns, lnum, text_close - 1, link_close, "")
    s = b + 1
  end
end

local function apply_line(buf, ns, lnum, raw)
  if raw == "" then return end
  -- Block math single-line: $$...$$ on one line — replace with unicode-rendered
  if raw:match("^%s*%$%$") and raw:match("%$%$%s*$") and not raw:match("^%s*%$%$%s*$") then
    local inner = raw:gsub("^%s*%$%$", ""):gsub("%$%$%s*$", "")
    local pretty = "  " .. unicodify_math(inner)
    set_mark(buf, ns, lnum, 0, {
      end_col = #raw,
      conceal = "",
      virt_text = { { pretty, HL.MathBlock } },
      virt_text_pos = "overlay",
      line_hl_group = HL.MathBlock,
      priority = 110,
    })
    return
  end
  -- ATX headings — accept `#`, `##` etc with OR without trailing space
  -- (CommonMark requires space; Jupyter/VSCode are lenient).
  local hashes = raw:match("^(#+)")
  if hashes and #hashes <= 6 and (raw:sub(#hashes + 1, #hashes + 1) ~= "#") then
    local level = #hashes
    local hl = HL["H" .. level]
    local prefix = ({ "█ ", "▌ ", "▎ ", "▏ ", "· ", "· " })[level] or "  "
    -- Conceal hashes; if a space follows, conceal it too.
    local conceal_end = #hashes
    if raw:sub(#hashes + 1, #hashes + 1) == " " then conceal_end = conceal_end + 1 end
    set_mark(buf, ns, lnum, 0, {
      end_col = conceal_end,
      conceal = "",
      virt_text = { { prefix, hl } },
      virt_text_pos = "inline",
      hl_mode = "combine",
      priority = 105,
    })
    set_mark(buf, ns, lnum, 0, { line_hl_group = hl, priority = 100 })
    inline_styling(buf, ns, lnum, raw)
    return
  end
  -- HR — fully conceal the line (no decoration). Render-markdown convention.
  if raw:match("^%s*[-_*]%s*[-_*]%s*[-_*][-_*%s]*$") then
    set_mark(buf, ns, lnum, 0, {
      end_col = #raw,
      conceal = "",
      hl_mode = "combine",
      priority = 200,
    })
    return
  end
  -- Quote: ^> text
  if raw:match("^>%s*") then
    set_mark(buf, ns, lnum, 0, { line_hl_group = HL.Quote, priority = 90 })
    inline_styling(buf, ns, lnum, raw)
    return
  end
  -- Bullet list
  local indent, marker = raw:match("^(%s*)([%-%*%+])%s+")
  if marker then
    set_mark(buf, ns, lnum, #indent, {
      end_col = #indent + 1,
      virt_text = { { "•", HL.Bullet } },
      virt_text_pos = "overlay",
      conceal = "",
      hl_mode = "combine",
    })
    inline_styling(buf, ns, lnum, raw)
    return
  end
  -- Numbered list
  local num_pre = raw:match("^(%s*%d+%.)%s+")
  if num_pre then
    set_mark(buf, ns, lnum, 0, { hl_group = HL.Bullet, end_col = #num_pre, hl_mode = "combine", priority = 100 })
    inline_styling(buf, ns, lnum, raw)
    return
  end
  -- Embedded image placeholder: ![alt](jupynvim-img:N) — fully conceal so
  -- the cell shows just the rendered image below, like VSCode does.
  if raw:match("!%[[^%]]*%]%(jupynvim%-img:%d+%)") then
    set_mark(buf, ns, lnum, 0, {
      end_col = #raw,
      conceal = "",
      priority = 200,
    })
    return
  end

  -- Plain
  inline_styling(buf, ns, lnum, raw)
end

-- ---------- public API ----------

-- Apply markdown extmarks to lines [start_line, end_line] (0-based, inclusive)
-- in `buf`, in namespace `ns`. Multi-line constructs (fenced code blocks,
-- block math) are tracked via a small state machine.
function M.render(buf, ns, start_line, end_line, render_width)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local total = vim.api.nvim_buf_line_count(buf)
  if start_line >= total then return end
  end_line = math.min(end_line, total - 1)
  local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line + 1, false)
  local heading_width = render_width or 60

  local in_fence = false
  local in_math_block = false

  for i, raw in ipairs(lines) do
    local lnum = start_line + i - 1
    -- Fenced code blocks ```...```
    if raw:match("^%s*```") then
      in_fence = not in_fence
      set_mark(buf, ns, lnum, 0, {
        line_hl_group = HL.Code,
        virt_text = { { string.rep("─", 60), HL.Code } },
        virt_text_pos = "overlay",
        conceal = "",
        hl_mode = "combine",
        priority = 110,
      })
    elseif in_fence then
      set_mark(buf, ns, lnum, 0, { line_hl_group = HL.Code, priority = 100 })
    -- Block math $$...$$ over multiple lines
    elseif (not in_math_block) and raw:match("^%s*%$%$%s*$") then
      in_math_block = true
      set_mark(buf, ns, lnum, 0, {
        line_hl_group = HL.MathBlock,
        priority = 110,
      })
    elseif in_math_block and raw:match("^%s*%$%$%s*$") then
      in_math_block = false
      set_mark(buf, ns, lnum, 0, { line_hl_group = HL.MathBlock, priority = 110 })
    elseif in_math_block then
      set_mark(buf, ns, lnum, 0, { line_hl_group = HL.MathBlock, priority = 100 })
    else
      -- Setext headings: text line followed by `===` (h1) or `---` (h2).
      -- Style the text line as a heading; fully conceal the underline below.
      local next_line = lines[i + 1]
      local is_setext_h1 = next_line and next_line:match("^=+%s*$")
      local is_setext_h2 = next_line and next_line:match("^%-+%s*$")
      if (is_setext_h1 or is_setext_h2) and raw ~= "" and not raw:match("^#+%s") then
        local level = is_setext_h1 and 1 or 2
        local hl = HL["H" .. level]
        set_mark(buf, ns, lnum, 0, { line_hl_group = hl, priority = 100 })
        inline_styling(buf, ns, lnum, raw)
        -- Conceal the entire underline-marker line — no decoration overlay.
        set_mark(buf, ns, lnum + 1, 0, {
          end_col = #(next_line or ""),
          conceal = "",
          hl_mode = "combine",
          priority = 200,
        })
      else
        apply_line(buf, ns, lnum, raw)
        -- ATX heading: NO underline virt_line. The styled heading text speaks for itself.
      end
    end
  end
end

return M
