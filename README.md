# jupynvim

VSCode-style Jupyter notebooks in Neovim. Real cells, real images, real LSP —
all rendered inline in a Kitty-graphics-capable terminal (Ghostty, Kitty,
WezTerm).

<p align="center">
  <video src="examples/demo.mp4" controls loop muted autoplay playsinline width="900"></video>
</p>

> If GitHub doesn't auto-render the video above, click
> [`examples/demo.mp4`](examples/demo.mp4).

## What it is

* Open any `.ipynb` like a regular file. No extension, no browser, no Jupyter
  Lab tab.
* Code cells, markdown cells, and outputs are framed inside virtual-line
  borders. Edit with full vim motions; `:w` saves the notebook.
* Code cells run on a real Jupyter kernel (any installed `kernelspec`).
  Outputs — text, errors, PNGs, animated GIFs — render inline.
* LSP works on `.ipynb`. basedpyright, pyright, ruff, pylsp all attach with
  the kernel's interpreter (so `numpy`, `matplotlib`, project deps resolve)
  and only diagnose code cells.

Self-contained: a Rust backend (`core/`) speaks the Jupyter wire protocol
directly to any kernel. A Lua frontend (`lua/jupynvim/`) renders cells with
extmarks and emits Kitty graphics escapes straight to `/dev/tty`. No
third-party image plugins.

## Requirements

* Neovim 0.11+
* A Kitty-graphics terminal: Ghostty 1.3+, Kitty, or WezTerm
* Rust toolchain (`cargo`) — built once on install
* Python with `ipykernel` for the kernel you want to use
* `magick` (ImageMagick 7) — required for animated GIF playback

Optional: `chafa` for ASCII-art image fallback on terminals without graphics.

## Install (lazy.nvim)

```lua
{
  "shengtselin/jupynvim",   -- adjust to your fork/org
  build = function()
    local core = vim.fn.stdpath("data") .. "/lazy/jupynvim/core"
    vim.fn.system({ "cargo", "build", "--release", "--manifest-path", core .. "/Cargo.toml" })
  end,
  config = function()
    require("jupynvim").setup({
      log_level = "info",
      -- "placeholder" (default), "kitty", or "chafa"
      image_renderer = "placeholder",
    })
  end,
}
```

After install, open any `.ipynb` and the kernel auto-starts based on the
notebook's `kernelspec` metadata.

## Keymaps (notebook buffer-local)

| Key | Action |
|-----|--------|
| `<S-CR>` / `<leader>nr` | Run current cell, advance |
| `<C-CR>` | Run current cell, stay |
| `<leader>nR` | Run all cells |
| `<leader>nA` / `nB` | Run all cells above / below |
| `<leader>na` / `nb` | Add cell above / below |
| `<leader>nd` | Delete current cell |
| `<leader>nk` / `nj` | Move cell up / down |
| `<leader>nm` / `ny` | Convert to markdown / code |
| `<leader>nc` / `nC` | Clear current cell output / clear all |
| `<leader>nI` | Save current cell's image to file |
| `<leader>nD` | Delete embedded image (markdown cell) |
| `<C-j>` / `<C-k>` | Enter the next / previous output in a scratch split |
| `<leader>nK` | Pick kernel (lists every installed kernelspec) |
| `<leader>ns` / `nS` | Start / stop kernel |
| `<leader>ni` | Interrupt kernel |
| `<leader>nx` | Restart kernel |
| `]c` / `[c` | Next / prev cell |
| `]i` / `[i` | Next / prev cell with image |
| `<leader>nL` | Force re-render |

## Commands

* `:JupynvimOpen <path>` — open a notebook
* `:JupynvimRunCell` / `:JupynvimRunAll`
* `:JupynvimKernel` / `:JupynvimRestart`
* `:JupynvimClearOutputs` / `:JupynvimClearCellOutput`
* `:JupynvimSaveImage [path]` / `:JupynvimDeleteImage`
* `:JupynvimImageMode {placeholder|kitty|chafa}` — switch renderer at runtime
* `:JupynvimReset` — close all sessions and reload the current buffer

## Architecture

```
Neovim (Lua)                Rust backend (jupynvim-core)         Kernel
─────────────               ───────────────────────────         ──────
buffer/extmarks    ⟷    msgpack-rpc/stdio    ⟷       ZMQ/HMAC    ⟷  ipykernel
Kitty graphics              jupyter wire protocol
                            nbformat read/write
                            kernelspec discovery
```

* **Frontend (Lua)** — `lua/jupynvim/`. Hijacks `*.ipynb`, renders cells with
  virtual-line borders + execution-count badges, places PNGs via the Kitty
  graphics protocol, manages keymaps. Manually attaches LSP because
  Neovim's `vim.lsp.enable` callback bails on non-empty `buftype`, which
  jupynvim needs (`acwrite`) to hijack `:w`.
* **Backend (Rust)** — `core/`. Owns ZMQ sockets to the kernel (one task per
  socket), HMAC-SHA256 signs every Jupyter message, parses/serialises
  `.ipynb` (nbformat v4) preserving unknown fields, routes iopub events to
  cells via `parent_msg_id`, decomposes animated GIFs into frame sequences
  via ImageMagick.

## LSP and the cleaned-text view

basedpyright treats the entire notebook buffer as one Python file, which
breaks badly: words like *`with both side bars intact`* in markdown turn into
fake `with` statements that propagate parse errors into the next code cell.

jupynvim patches `vim.lsp._buf_get_full_text` to return the buffer with every
non-code line replaced by an empty line (line numbers preserved so
diagnostics still map back). It forces `flags.allow_incremental_sync = false`
on python LSPs so every change re-sends the cleaned text via Full sync.
Combined with treesitter `set_included_regions`, both the parser and the
LSP see only code.

The kernel's `argv[0]` interpreter and its real `sys.path` site-packages dirs
are pushed to basedpyright as `python.pythonPath` and
`basedpyright.analysis.extraPaths` before `vim.lsp.start`, so imports resolve
against the env that actually runs the notebook (Homebrew Python's
site-packages live outside the binary's prefix, hence `extraPaths`).

## Logs

* Backend: `~/Library/Caches/jupynvim/core.log` (macOS) or
  `$XDG_CACHE_HOME/jupynvim/core.log`. Set `JUPYNVIM_LOG=debug` for verbose.
* Frontend: `vim.fn.stdpath("cache") .. "/jupynvim/lua.log"`.

## Limitations

* Kitty graphics only. Terminals without graphics fall back to ASCII via
  `chafa` (set `image_renderer = "chafa"`).
* Ghostty 1.3 doesn't implement the Kitty animation protocol, so animated
  GIFs are driven by re-transmitting frames on a `vim.loop` timer.
* Multi-image markdown cells are supported, but image deletion via
  `<leader>nD` prompts when more than one is present in the cell.

## License

MIT — see [`LICENSE`](LICENSE).
