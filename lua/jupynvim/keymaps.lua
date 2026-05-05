-- Buffer-local keybindings for a notebook buffer.

local M = {}

local function map(buf, mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, desc = desc })
end

function M.attach(buf, api)
  -- api = the jupynvim public api (init.lua) used to invoke ops
  -- Run cell with shift+enter (advance) and ctrl+enter (stay)
  map(buf, { "n", "i" }, "<S-CR>", function() api.run_cell(buf, { advance = true }) end, "Run cell + advance")
  map(buf, { "n", "i" }, "<C-CR>", function() api.run_cell(buf, { advance = false }) end, "Run cell")
  -- Some terminals send <CR> for shift+enter; provide leader fallback
  map(buf, "n", "<leader>nr", function() api.run_cell(buf, { advance = true }) end, "Run cell + advance")
  map(buf, "n", "<leader>nR", function() api.run_all(buf) end, "Run all cells")
  map(buf, "n", "<leader>nA", function() api.run_above(buf) end, "Run all cells above")
  map(buf, "n", "<leader>nB", function() api.run_below(buf) end, "Run all cells below")

  -- Add / delete / move cells
  map(buf, "n", "<leader>na", function() api.add_cell(buf, "above") end, "Add cell above")
  map(buf, "n", "<leader>nb", function() api.add_cell(buf, "below") end, "Add cell below")
  map(buf, "n", "<leader>nd", function() api.delete_cell(buf) end, "Delete cell")
  map(buf, "n", "<leader>nk", function() api.move_cell(buf, -1) end, "Move cell up")
  map(buf, "n", "<leader>nj", function() api.move_cell(buf, 1) end, "Move cell down")

  -- Convert cell type
  map(buf, "n", "<leader>nm", function() api.set_cell_type(buf, "markdown") end, "→ markdown cell")
  map(buf, "n", "<leader>ny", function() api.set_cell_type(buf, "code") end, "→ code cell")

  -- Kernel
  map(buf, "n", "<leader>nK", function() api.kernel_picker(buf) end, "Pick kernel")
  map(buf, "n", "<leader>ns", function() api.start_kernel(buf) end, "Start kernel")
  map(buf, "n", "<leader>nS", function() api.stop_kernel(buf) end, "Stop kernel")
  map(buf, "n", "<leader>ni", function() api.interrupt_kernel(buf) end, "Interrupt kernel")
  map(buf, "n", "<leader>nx", function() api.restart_kernel(buf) end, "Restart kernel")

  -- Cell navigation
  map(buf, "n", "]c", function() api.jump_cell(buf, 1) end, "Next cell")
  map(buf, "n", "[c", function() api.jump_cell(buf, -1) end, "Prev cell")
  map(buf, "n", "]i", function() api.jump_image(buf, 1) end, "Next image cell")
  map(buf, "n", "[i", function() api.jump_image(buf, -1) end, "Prev image cell")

  -- Refresh display
  map(buf, "n", "<leader>nL", function() api.refresh(buf) end, "Refresh notebook display")
end

return M
