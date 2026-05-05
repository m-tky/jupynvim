# jupynvim

VSCode-style Jupyter notebooks in Neovim, designed for terminals that support
the Kitty graphics protocol (Ghostty, Kitty, WezTerm).

Self-contained: a Rust backend (`core/`) speaks the Jupyter wire protocol
directly to any Jupyter kernel. A Lua frontend (`lua/jupynvim/`) renders cells
as visual blocks in a Neovim buffer with extmarks and emits Kitty graphics
escapes for inline plots.

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
  graphics protocol written directly to `/dev/tty`, manages keymaps.
* **Backend (Rust)** — `core/`. Owns ZMQ sockets to the kernel (one task per
  socket so send/recv don't conflict), HMAC-SHA256 signs every Jupyter
  message, parses/serialises `.ipynb` (nbformat v4) preserving unknown fields,
  routes iopub events to cells via parent_msg_id.

## Build

The plugin builds itself via `lazy.nvim`'s `build` hook. Manual:

```bash
cd ~/.config/nvim/jupynvim/core
cargo build --release
```

A conda env named `jupynvim` ships the Rust toolchain + Python deps:

```bash
conda create -n jupynvim -c conda-forge -y python=3.12 rust ipykernel jupyter_client nbformat pyzmq
```

## Keys (notebook buffer-local)

| Key | Action |
|-----|--------|
| `<S-CR>` | Run current cell, advance to next |
| `<C-CR>` | Run current cell, stay |
| `<leader>nr` | Run current cell + advance |
| `<leader>nR` | Run all cells |
| `<leader>nA` | Run all cells above |
| `<leader>nB` | Run all cells below |
| `<leader>na` / `nb` | Add cell above / below |
| `<leader>nd` | Delete current cell |
| `<leader>nk` / `nj` | Move cell up / down |
| `<leader>nm` / `ny` | Convert to markdown / code |
| `<leader>nK` | Pick kernel |
| `<leader>ns` / `nS` | Start / stop kernel |
| `<leader>ni` | Interrupt kernel |
| `<leader>nx` | Restart kernel |
| `]c` / `[c` | Next / prev cell |
| `<leader>nL` | Force re-render |

## Logs

* Backend: `~/Library/Caches/jupynvim/core.log` (macOS) or
  `$XDG_CACHE_HOME/jupynvim/core.log`. Set `JUPYNVIM_LOG=debug` to verbose.
* Frontend: `vim.fn.stdpath("cache") .. "/jupynvim/lua.log"`.
