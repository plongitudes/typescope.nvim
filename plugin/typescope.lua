if vim.g.loaded_typescope then
  return
end
vim.g.loaded_typescope = true

if vim.fn.has("nvim-0.10") ~= 1 then
  vim.notify_once("typescope.nvim requires Neovim 0.10+", vim.log.levels.ERROR)
  return
end

local subcommands = { "open", "close", "toggle", "hover", "spike" }

vim.api.nvim_create_user_command("TypeScope", function(opts)
  local sub = opts.fargs[1] or "toggle"
  local args = { unpack(opts.fargs, 2) }
  require("typescope").dispatch(sub, args)
end, {
  nargs = "*",
  complete = function(arglead, cmdline, _)
    -- only complete the first argument; later args are subcommand-specific
    local words = vim.split(cmdline, "%s+", { trimempty = true })
    if #words > 2 or (#words == 2 and arglead == "") then
      return {}
    end
    return vim.tbl_filter(function(s)
      return vim.startswith(s, arglead)
    end, subcommands)
  end,
  desc = "TypeScope: visualize type structures for the function under the cursor",
})

-- <Plug> mappings so users can bind without writing lua callbacks:
--   vim.keymap.set("n", "<leader>ts", "<Plug>(TypeScopeToggle)")
vim.keymap.set("n", "<Plug>(TypeScopeToggle)", function()
  require("typescope").toggle()
end, { desc = "TypeScope: toggle float" })
vim.keymap.set("n", "<Plug>(TypeScopeOpen)", function()
  require("typescope").open()
end, { desc = "TypeScope: open float (again to focus)" })
vim.keymap.set("n", "<Plug>(TypeScopeHover)", function()
  require("typescope").hover()
end, { desc = "TypeScope: structure for functions, builtin hover otherwise (K replacement)" })
