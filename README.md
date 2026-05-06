# jupynvim

Open `.ipynb` files in Neovim and edit them like a real notebook. Cells with
borders, inline images, real Jupyter kernels, and an LSP that actually
understands the file. Built on a Rust backend that talks the Jupyter wire
protocol directly, with no Python remote-plugin layer.

<p align="center">
  <video src="examples/demo.mp4" controls loop muted autoplay playsinline width="900"></video>
</p>

> If GitHub doesn't auto-play the video above, click
> [`examples/demo.mp4`](examples/demo.mp4).

## Highlights

- Open and save `.ipynb` files natively. `:w` writes nbformat v4 JSON, and
  unknown fields round-trip untouched.
- Cells render as visual blocks with virtual-line borders and execution-count
  badges. You edit inside cells with vim motions, and treesitter highlights
  only the code lines.
- Real Jupyter kernels via the wire protocol over ZMQ with HMAC-SHA256.
  Pick any installed kernelspec. Outputs render inside the cell, including
  text, errors, PNGs, and animated GIFs.
- Inline images using the Kitty graphics protocol. Native PNG placement, not
  ASCII art, unless you ask for it. Animated GIFs loop at native speed via
  ImageMagick frame extraction.
- Markdown cells render with their own highlight overlay. Embedded
  `data:image/...;base64,...` URIs get rewritten to short placeholders so the
  buffer stays small while images still display.
- LSP that works on `.ipynb`. basedpyright, pyright, pylsp, or ruff attach
  with the kernel's interpreter so `numpy`, `matplotlib`, and project deps
  resolve. Diagnostics are scoped to code-cell line ranges so markdown text
  doesn't drown you in fake errors.
- Multi-image markdown cells are supported. `<leader>nD` deletes one image
  and `u` brings it back.
- One Rust binary, one Lua plugin. No `pynvim`, no `jupyter_client`, no
  `image.nvim`, no Node-based notebook server.

## Requirements

- Neovim 0.11 or newer.
- A Kitty-graphics terminal. Ghostty 1.3 and later, kitty, or WezTerm.
- Rust toolchain (`cargo`), built once on plugin install.
- A Jupyter kernel installed for the language you intend to use. For Python
  that's `pip install ipykernel` inside whatever env you want to run
  notebooks against.
- ImageMagick 7 (`magick`) is required for animated GIF playback. Static
  images work without it.

`chafa` is optional. Install it if you want an ASCII-art fallback for
terminals without graphics support.

## Install

With [`lazy.nvim`](https://github.com/folke/lazy.nvim):

```lua
{
  "shengtselin/jupynvim",
  build = function()
    local core = vim.fn.stdpath("data") .. "/lazy/jupynvim/core"
    vim.fn.system({
      "cargo", "build", "--release",
      "--manifest-path", core .. "/Cargo.toml",
    })
  end,
  config = function()
    require("jupynvim").setup({
      log_level = "info",
      image_renderer = "placeholder",  -- "placeholder", "kitty", or "chafa"
    })
  end,
}
```

That's it. Open any `.ipynb` and the kernel auto-starts based on the
notebook's `kernelspec` metadata.

## Quick start

Open an existing notebook with `:edit my-notebook.ipynb` or create a fresh
one with `:JupynvimOpen new-notebook.ipynb`.

Inside the buffer, move your cursor into a code cell and press `<leader>nr`
or `<S-CR>`. The execution count badge cycles to `[*]`, then `[1]`, and the
output appears below the code framed by the same border. `<leader>nb` adds a
code cell below, `<leader>nm` converts it to markdown, and `<leader>nK`
opens a picker listing every installed kernelspec.

`:w` saves. `:wqa` works as expected even if you only ran cells. jupynvim
flips the `modified` flag on every output event so vim's "unchanged" check
doesn't skip the save.

## Concepts

A jupynvim buffer is one Neovim buffer per `.ipynb` file. Cells are line
ranges separated by an invisible marker, `# %%[jupynvim:cell-sep]`,
concealed at runtime. Cell type, execution count, and outputs live as state
on the notebook object. The buffer text contains only what you'd type as
the cell's source.

Cells aren't floating windows or scratch buffers. Splits, marks, motions,
and search all work like a normal buffer. The visual block appearance comes
from extmark virtual text, not separate windows.

The Rust backend (`jupynvim-core`) owns the Jupyter connection. It runs as
a single subprocess and is shared across every open notebook. Kernel events
flow back as msgpack-RPC notifications which the Lua side maps to cells.

When you open a notebook, jupynvim reads the file via the backend
(round-tripping unknown nbformat fields), creates a buffer with
`buftype=acwrite` so `:w` routes through our `BufWriteCmd`, auto-starts the
kernel from the notebook's `kernelspec.name`, and manually attaches LSP.
Neovim's built-in `vim.lsp.enable` callback bails on non-empty `buftype`,
so jupynvim replicates the FileType callback's logic without that guard,
then injects the kernel's `pythonPath` and `analysis.extraPaths` (harvested
from `python -c "import sys"`) so import resolution matches the env you'll
actually run.

## Commands

| Command | Description |
|---|---|
| `:JupynvimOpen <path>` | Open a notebook. Also handles `:edit *.ipynb`. |
| `:JupynvimRunCell` | Run the cell under cursor. |
| `:JupynvimRunAll` | Run every code cell in order. |
| `:JupynvimKernel` | Pick a kernelspec from the installed list. |
| `:JupynvimRestart` | Restart the active kernel. |
| `:JupynvimClearOutputs` | Clear outputs from every code cell. |
| `:JupynvimClearCellOutput` | Clear output for the current cell only. |
| `:JupynvimSaveImage [path]` | Save the current cell's image to disk. |
| `:JupynvimDeleteImage` | Delete an embedded image from a markdown cell. |
| `:JupynvimImageMode {placeholder\|kitty\|chafa}` | Switch image renderer at runtime. |
| `:JupynvimReset` | Close every session, wipe state, reload current buffer. |
| `:JupynvimDebug` | Print buffer/cell/notebook state. |

## Keymaps

All notebook keymaps are buffer-local. They only exist while you're inside
an `.ipynb`.

### Cell execution

| Key | Action |
|---|---|
| `<S-CR>` or `<leader>nr` | Run cell, advance to next |
| `<C-CR>` | Run cell, stay |
| `<leader>nR` | Run all cells |
| `<leader>nA` or `<leader>nB` | Run all cells above or below |

### Cell editing

| Key | Action |
|---|---|
| `<leader>na` or `<leader>nb` | Add cell above or below |
| `<leader>nd` | Delete cell |
| `<leader>nk` or `<leader>nj` | Move cell up or down |
| `<leader>nm` or `<leader>ny` | Convert to markdown or code |
| `<leader>nc` or `<leader>nC` | Clear current cell output, or clear all |
| `]c` or `[c` | Jump to next or prev cell |

### Outputs and images

| Key | Action |
|---|---|
| `<C-j>` or `<C-k>` | Enter the next or prev cell's output in a scratch split with full vim motions |
| `<leader>nI` | Save current cell's image to file |
| `<leader>nD` | Delete an embedded image from a markdown cell |
| `]i` or `[i` | Jump to next or prev cell with an image |

### Kernel control

| Key | Action |
|---|---|
| `<leader>nK` | Pick kernel |
| `<leader>ns` or `<leader>nS` | Start or stop kernel |
| `<leader>ni` | Interrupt kernel |
| `<leader>nx` | Restart kernel |
| `<leader>nL` | Force re-render |

## Configuration

```lua
require("jupynvim").setup({
  -- Verbosity for both the Rust backend and the Lua frontend.
  log_level = "info",  -- trace, debug, info, warn, or error

  -- How code-cell outputs and embedded markdown images are rendered.
  --   "placeholder" uses the Kitty Unicode placeholder protocol. The image
  --                 is anchored to buffer text and stays put when scrolling.
  --                 Required for animated GIFs.
  --   "kitty"       uses direct kitty placement. Lives at fixed screen
  --                 coordinates and doesn't follow scroll.
  --   "chafa"       is an ASCII-art fallback. Use this on terminals without
  --                 graphics support.
  image_renderer = "placeholder",

  -- Override the path to the jupynvim-core binary. Auto-detected from the
  -- plugin directory if unset.
  core_path = nil,
})
```

## How the LSP integration works

Two non-obvious tricks make basedpyright behave on `.ipynb`.

The first is a cleaned-text view to the LSP. The Python parser sees the
buffer as one file, so phrases like *with both side bars intact* in a
markdown cell get parsed as a `with` statement and the parse error
propagates into the next code cell's diagnostics. jupynvim patches
`vim.lsp._buf_get_full_text` to return the buffer with non-code lines
blanked out (line numbers preserved so diagnostics still map back). It
also forces `flags.allow_incremental_sync = false` so every `didChange`
re-routes through the patched function. The LSP only ever sees code.

The second is a kernel-aware `pythonPath`. basedpyright probes the
filesystem under `<pythonPath>/../lib/site-packages` rather than executing
the interpreter, so Homebrew Python breaks `import numpy` because its
site-packages live in `/opt/homebrew/lib/python3.x/site-packages` rather
than under the binary's prefix. jupynvim runs the kernel's interpreter
once at startup, harvests every `site-packages` and `dist-packages` dir
from `sys.path`, and injects them as `analysis.extraPaths` before
`vim.lsp.start`.

Treesitter is also restricted to code-cell byte ranges via
`set_included_regions`. Same problem space, different fix point.

## Architecture

```
Neovim (Lua)               Rust backend (jupynvim-core)            Kernel
─────────────              ───────────────────────────             ──────
buffer/extmarks    ⟷    msgpack-rpc / stdio    ⟷       ZMQ/HMAC    ⟷  ipykernel
Kitty graphics             jupyter wire protocol
                           nbformat v4 read/write
                           kernelspec discovery
```

The Lua frontend hijacks `*.ipynb` via `BufReadCmd`, renders cells with
virtual-line borders, transmits PNG bytes via the Kitty graphics protocol
straight to `/dev/tty`, drives gif animation on a `vim.loop` timer, and
owns keymaps and commands.

The Rust backend runs one async task per ZMQ socket so `send` and `recv`
don't conflict, HMAC-SHA256 signs every message, parses and serializes
`.ipynb` (nbformat v4) preserving unknown fields, routes iopub events to
cells via `parent_msg_id`, and decomposes animated GIFs into a frame
sequence with ImageMagick.

## Logs

Backend logs to `~/Library/Caches/jupynvim/core.log` on macOS and
`$XDG_CACHE_HOME/jupynvim/core.log` elsewhere. Set `JUPYNVIM_LOG=debug`
for verbose output. The Lua frontend logs to
`vim.fn.stdpath("cache") .. "/jupynvim/lua.log"`.

## Limitations

Kitty graphics or bust. Without a graphics-capable terminal, set
`image_renderer = "chafa"` for ASCII output.

Ghostty 1.3 doesn't implement the Kitty animation protocol, so animated
GIFs are driven by re-transmitting frames on a timer. Cheap, works
everywhere, but consumes a small amount of CPU while playing.

One backend instance is shared across all open notebooks. Restarting it
with `:JupynvimReset` restarts every kernel.

## Thanks

[Magma](https://github.com/dccsillag/magma-nvim) and
[molten-nvim](https://github.com/benlubas/molten-nvim) proved that Jupyter
in Neovim is a real workflow worth investing in. The Jupyter team
documented an excellent
[wire protocol](https://jupyter-client.readthedocs.io/en/stable/messaging.html).
Kitty and Ghostty built the graphics protocol that makes terminal-native
notebooks possible at all.

## License

MIT. See [`LICENSE`](LICENSE).
