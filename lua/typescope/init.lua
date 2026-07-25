local M = {}

--- Optional: users may call setup() with overrides, or skip it entirely.
---@param opts? table
function M.setup(opts)
  require("typescope.config").setup(opts)
end

--- Open the TypeScope float for the function under the cursor.
function M.open()
  vim.notify("typescope: LSP pipeline not implemented yet (phase 3)", vim.log.levels.INFO)
end

--- Close any open TypeScope float.
function M.close()
  vim.notify("typescope: LSP pipeline not implemented yet (phase 3)", vim.log.levels.INFO)
end

--- Toggle the TypeScope float.
function M.toggle()
  vim.notify("typescope: LSP pipeline not implemented yet (phase 3)", vim.log.levels.INFO)
end

--- :TypeScope <sub> entry point. Kept in one place so plugin/typescope.lua
--- stays a thin shim that never requires anything at startup.
---@param sub string
---@param args string[]
function M.dispatch(sub, args)
  if sub == "spike" then
    require("typescope.spike").run(args)
  elseif sub == "open" then
    M.open()
  elseif sub == "close" then
    M.close()
  elseif sub == "toggle" then
    M.toggle()
  else
    vim.notify(("typescope: unknown subcommand %q"):format(sub), vim.log.levels.ERROR)
  end
end

return M
