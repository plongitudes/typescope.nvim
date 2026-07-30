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
---@field ctrl typescope.Controller
---@field token typescope.CancelToken
---@field client vim.lsp.Client
---@field augroup integer
---@field srcbuf integer

---@type typescope.Session?
local session = nil

-- auto-LLM failure is reported once per nvim session, not once per float
local llm_auto_warned = false

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
---@param meta { header?: string, docstring?: string }?
---@param token typescope.CancelToken
---@param client vim.lsp.Client
---@param sig_result table? signatureHelp result (activeParameter only)
local function show(srcbuf, roots, meta, token, client, sig_result)
  local cfg = require("typescope.config").get()
  local float = require("typescope.float")
  local render = require("typescope.render")
  local styles = require("typescope.styles")
  local interact = require("typescope.interact")
  local lsp = require("typescope.lsp")
  require("typescope.highlights").apply()

  -- mark the active parameter (cursor inside the call's argument list),
  -- matched by name — see lsp.active_param for why not by index
  local active_name = lsp.active_param(sig_result)
  if active_name then
    for _, root in ipairs(roots) do
      if root.kind == "param" and root.name == active_name then
        root.active = true
        break
      end
    end
  end

  local max_width = require("typescope.config").resolved_max_width()
  local render_opts = {
    style = styles.get(cfg.ui.style),
    max_width = max_width,
    align = cfg.ui.align,
    show_examples = cfg.show_examples and cfg.example_mode ~= "none",
    example_kind = cfg.example_mode == "llm" and "llm" or "heuristic",
    lang = vim.bo[srcbuf].filetype,
    -- unified float (U1): call-shape header + docstring section, absorbing
    -- the retired anchor float's content
    header = meta and meta.header or nil,
    docstring = meta and meta.docstring or nil,
    docstring_expanded = false,
    docstring_pos = cfg.ui.docstring,
  }
  local result = render.render(roots, render_opts)
  local width = math.min(max_width, math.max(result.width, 30))
  local height = math.min(cfg.ui.max_height, #result.lines)

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
    on_llm = function(tree_roots, done, on_progress)
      if session then
        require("typescope.examples").llm(tree_roots, session.token, done, on_progress)
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

  -- quiet marker on the call line: TypeScope has data here
  local cursor = vim.api.nvim_win_get_cursor(0)
  require("typescope.hint").place(srcbuf, cursor[1] - 1)

  -- pre-load the model in the background so the first E press is warm
  if cfg.ollama.enabled then
    require("typescope.examples.ollama").warmup(cfg.ollama)
  end

  -- example_mode = "llm": generate automatically on open. The float is fully
  -- usable meanwhile (heuristics show immediately); LLM values swap in when
  -- the background request lands. E stays useful for newly expanded leaves.
  if cfg.ollama.enabled and cfg.example_mode == "llm" then
    local spinner = require("typescope.anim").title_spinner(handle.win, "generating")
    local function live()
      return session ~= nil and session.token == token and vim.api.nvim_win_is_valid(handle.win)
    end
    require("typescope.examples").llm(roots, token, function(ok, err)
      spinner.stop()
      if not live() then
        return
      end
      if ok then
        ctrl.refresh()
      elseif err and not llm_auto_warned then
        llm_auto_warned = true -- once per session; every open would otherwise nag
        vim.notify("typescope: auto LLM examples unavailable — " .. err, vim.log.levels.WARN)
      end
    end, function()
      if live() then
        ctrl.refresh() -- batch landed: swap its rows in
      end
    end)
  end

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
      -- leaving the source buffer INTO our float is the focus gesture, not a
      -- dismissal. The scheduled check is bound to THIS session's window: a
      -- stale check surviving a close must not murder the next session.
      vim.schedule(function()
        if
          session
          and session.handle.win == handle.win
          and vim.api.nvim_get_current_win() ~= handle.win
        then
          M.close()
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    pattern = tostring(handle.win),
    callback = function()
      M.close()
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
    local roots, meta_or_err = resolve.function_scope(client, bufnr, win, token)
    if async.stale(token) then
      return
    end
    if not roots then
      if opts.on_unresolved then
        opts.on_unresolved()
      elseif not opts.silent then
        vim.notify("typescope: " .. tostring(meta_or_err), vim.log.levels.INFO)
      end
      return
    end
    -- signatureHelp still requested, but only for activeParameter now
    local sig_result = lsp.signature_help(client, bufnr, win, token)
    if async.stale(token) then
      return
    end
    show(bufnr, roots, meta_or_err, token, client, sig_result)
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
