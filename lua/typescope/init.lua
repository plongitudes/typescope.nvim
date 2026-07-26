local M = {}

--- Optional: users may call setup() with overrides, or skip it entirely.
---@param opts? table
function M.setup(opts)
  require("typescope.config").setup(opts)
end

---@class typescope.Session
---@field handle typescope.FloatHandle
---@field ctrl typescope.Controller
---@field token typescope.CancelToken
---@field client vim.lsp.Client
---@field augroup integer
---@field srcbuf integer

---@type typescope.Session?
local session = nil

--- Close any open TypeScope float and cancel in-flight work.
function M.close()
  if not session then
    return
  end
  local s = session
  session = nil
  require("typescope.async").cancel(s.token)
  pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
  require("typescope.float").close(s.handle)
end

---@param srcbuf integer
---@param roots typescope.Node[]
---@param token typescope.CancelToken
---@param client vim.lsp.Client
local function show(srcbuf, roots, token, client)
  local cfg = require("typescope.config").get()
  local float = require("typescope.float")
  local render = require("typescope.render")
  local styles = require("typescope.styles")
  local interact = require("typescope.interact")
  require("typescope.highlights").apply()

  local render_opts = {
    style = styles.get(cfg.ui.style),
    max_width = cfg.ui.max_width,
    show_examples = cfg.show_examples,
    example_kind = cfg.example_mode == "llm" and "llm" or "heuristic",
    lang = vim.bo[srcbuf].filetype,
  }
  local result = render.render(roots, render_opts)
  local width = math.min(cfg.ui.max_width, math.max(result.width, 30))
  local height = math.min(cfg.ui.max_height, #result.lines)

  -- phase 3: cursor anchor; signature-float anchoring lands in phase 4
  local handle = float.open({
    lines = result.lines,
    highlights = result.highlights,
    ts_injections = result.ts_injections,
    lang = render_opts.lang,
    title = " typescope ",
    footer = " ? help ",
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    border = cfg.ui.border,
    enter = false, -- first trigger opens unfocused; second focuses (hover convention)
  })

  local ctrl = interact.attach({
    handle = handle,
    roots = roots,
    opts = render_opts,
    width = width,
    max_height = cfg.ui.max_height,
    on_close = M.close,
    on_recurse = function(node, done)
      if session then
        require("typescope.resolve").recurse(session.client, node, session.token, done)
      end
    end,
  })

  local augroup = vim.api.nvim_create_augroup("TypeScopeSession", { clear = true })
  session = {
    handle = handle,
    ctrl = ctrl,
    token = token,
    client = client,
    augroup = augroup,
    srcbuf = srcbuf,
  }

  -- the float follows the builtin hover contract: any movement or edit in the
  -- source buffer dismisses it
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter" }, {
    group = augroup,
    buffer = srcbuf,
    callback = M.close,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = augroup,
    buffer = srcbuf,
    callback = function()
      -- leaving the source buffer INTO our float is the focus gesture, not a dismissal
      vim.schedule(function()
        if session and vim.api.nvim_get_current_win() ~= session.handle.win then
          M.close()
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(handle.win),
    callback = function()
      if session and session.handle.win == handle.win then
        M.close()
      end
    end,
  })
end

--- Open the TypeScope float for the function under the cursor; if already
--- open, focus it (arming the tree keymaps).
function M.open()
  if session and vim.api.nvim_win_is_valid(session.handle.win) then
    vim.api.nvim_set_current_win(session.handle.win)
    return
  end
  M.close()

  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local lsp = require("typescope.lsp")
  local client = lsp.client_for(bufnr)
  if not client then
    vim.notify("typescope: no LSP client with definition support attached to this buffer", vim.log.levels.WARN)
    return
  end

  local async = require("typescope.async")
  local token = async.token()
  async.run(function()
    local roots, err = require("typescope.resolve").function_scope(client, bufnr, win, token)
    if async.stale(token) then
      return
    end
    if not roots then
      vim.notify("typescope: " .. err, vim.log.levels.INFO)
      return
    end
    show(bufnr, roots, token, client)
  end)
end

--- Toggle the TypeScope float.
function M.toggle()
  if session then
    M.close()
  else
    M.open()
  end
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
