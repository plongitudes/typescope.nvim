local M = {}

--- Optional: users may call setup() with overrides, or skip it entirely.
---@param opts? table
function M.setup(opts)
  local cfg = require("typescope.config").setup(opts)
  if cfg.trigger == "hover" then
    M._enable_hover()
  end
end

-- Suppression key of the last CursorHold attempt: don't re-fire the pipeline
-- while the cursor sits on the same word of the same line (v1 heuristic;
-- revisit if it feels over- or under-eager).
local last_hover_key = nil

function M._enable_hover()
  local group = vim.api.nvim_create_augroup("TypeScopeHover", { clear = true })
  vim.api.nvim_create_autocmd("CursorHold", {
    group = group,
    desc = "TypeScope: auto-open on cursor rest (trigger = 'hover')",
    callback = function()
      if vim.fn.mode() ~= "n" or not require("typescope.lsp").client_for(0) then
        return
      end
      local pos = vim.api.nvim_win_get_cursor(0)
      local key = ("%d:%d:%s"):format(vim.api.nvim_get_current_buf(), pos[1], vim.fn.expand("<cword>"))
      if key == last_hover_key then
        return
      end
      last_hover_key = key
      M.open({ silent = true })
    end,
  })
end

---@class typescope.Session
---@field handle typescope.FloatHandle
---@field sig typescope.FloatHandle? anchored signature float (nil when cursor-anchored)
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
  local float = require("typescope.float")
  float.close(s.handle)
  float.close(s.sig)
end

---@param srcbuf integer
---@param roots typescope.Node[]
---@param token typescope.CancelToken
---@param client vim.lsp.Client
---@param sig_result table? signatureHelp result for the anchor float
---@param hover_lines string[]? hover markdown, the anchor fallback
local function show(srcbuf, roots, token, client, sig_result, hover_lines)
  local cfg = require("typescope.config").get()
  local float = require("typescope.float")
  local render = require("typescope.render")
  local styles = require("typescope.styles")
  local interact = require("typescope.interact")
  local lsp = require("typescope.lsp")
  require("typescope.highlights").apply()

  -- mark the active parameter (cursor inside the call's argument list)
  local active = lsp.active_param(sig_result)
  if active and roots[active + 1] and roots[active + 1].kind == "param" then
    roots[active + 1].active = true
  end

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

  -- anchor: below the signature/hover float when configured and available,
  -- else at the cursor
  local sig_handle
  local position = { relative = "cursor", row = 1, col = 0 }
  if cfg.ui.anchor == "signature" then
    local md = sig_result and lsp.signature_markdown(sig_result, vim.bo[srcbuf].filetype) or hover_lines
    if md then
      sig_handle = float.open_markdown(md, { border = cfg.ui.border, max_width = cfg.ui.max_width })
    end
    if sig_handle then
      local row, col, sig_width = float.below(sig_handle.win)
      width = math.max(width, sig_width) -- visually connected: at least as wide
      position = { relative = "editor", row = row, col = col }
    end
  end

  local handle = float.open({
    lines = result.lines,
    highlights = result.highlights,
    ts_injections = result.ts_injections,
    lang = render_opts.lang,
    title = " typescope ",
    footer = " ? help ",
    relative = position.relative,
    row = position.row,
    col = position.col,
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
    sig = sig_handle,
    ctrl = ctrl,
    token = token,
    client = client,
    augroup = augroup,
    srcbuf = srcbuf,
  }

  -- quiet marker on the call line: TypeScope has data here
  local cursor = vim.api.nvim_win_get_cursor(0)
  require("typescope.hint").place(srcbuf, cursor[1] - 1)

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
    pattern = tostring(handle.win) .. (sig_handle and ("," .. sig_handle.win) or ""),
    callback = function()
      M.close() -- either float dying takes both down
    end,
  })
end

--- K-takeover entry: TypeScope when the symbol under the cursor is a
--- function, plain builtin hover otherwise. Pressing again focuses the float
--- (same double-K convention as builtin hover).
function M.hover()
  if session and vim.api.nvim_win_is_valid(session.handle.win) then
    vim.api.nvim_set_current_win(session.handle.win)
    return
  end
  M.open({
    silent = true,
    on_unresolved = function()
      vim.lsp.buf.hover()
    end,
  })
end

--- Open the TypeScope float for the function under the cursor; if already
--- open, focus it (arming the tree keymaps).
---@param opts? { silent?: boolean, on_unresolved?: fun() } silent: no notifications (hover trigger); on_unresolved: called instead when the pipeline can't produce a tree
function M.open(opts)
  opts = opts or {}
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
    if opts.on_unresolved then
      opts.on_unresolved()
    elseif not opts.silent then
      vim.notify("typescope: no LSP client with definition support attached to this buffer", vim.log.levels.WARN)
    end
    return
  end

  local async = require("typescope.async")
  local token = async.token()
  async.run(function()
    local resolve = require("typescope.resolve")
    local roots, err = resolve.function_scope(client, bufnr, win, token)
    if async.stale(token) then
      return
    end
    if not roots then
      if opts.on_unresolved then
        opts.on_unresolved()
      elseif not opts.silent then
        vim.notify("typescope: " .. err, vim.log.levels.INFO)
      end
      return
    end
    local sig_result = lsp.signature_help(client, bufnr, win, token)
    if async.stale(token) then
      return
    end
    local hover_lines
    if not sig_result and require("typescope.config").get().ui.anchor == "signature" then
      hover_lines = lsp.hover_markdown(client, bufnr, win, token)
      if async.stale(token) then
        return
      end
    end
    show(bufnr, roots, token, client, sig_result, hover_lines)
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
  elseif sub == "hover" then
    M.hover()
  elseif sub == "close" then
    M.close()
  elseif sub == "toggle" then
    M.toggle()
  else
    vim.notify(("typescope: unknown subcommand %q"):format(sub), vim.log.levels.ERROR)
  end
end

return M
