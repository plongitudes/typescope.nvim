local M = {}

--- Optional: users may call setup() with overrides, or skip it entirely.
---@param opts? table
--- Each of these is called unconditionally and decides for itself, the way
--- _enable_warmstart already did. config.setup advertises that calling it more
--- than once is safe; the wiring has to hold up its end, or a second setup()
--- turning a feature back OFF leaves its autocmds installed and running.
function M.setup(opts)
  local cfg = require("typescope.config").setup(opts)
  M._enable_hover(cfg)
  require("typescope.insert").set_enabled(cfg.insert_mode.enabled)
  M._enable_warmstart(cfg)
end

-- Suppression key of the last CursorHold attempt: don't re-fire the pipeline
-- while the cursor sits on the same word of the same line (v1 heuristic;
-- revisit if it feels over- or under-eager).
local last_hover_key = nil

---@param cfg typescope.Config
function M._enable_hover(cfg)
  -- the group is created (and so cleared) whichever way the trigger is set:
  -- that is what takes the autocmd down again when a later setup() switches
  -- back to "manual"
  local group = vim.api.nvim_create_augroup("TypeScopeHover", { clear = true })
  if cfg.trigger ~= "hover" then
    return
  end
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
      -- auto-open must never yank the cursor out of the code, whatever
      -- ui.focus says; K on the open float is the focus gesture
      M.open({ silent = true, focus = false })
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

-- idle prefetch: single-flight token + the same word-suppression heuristic
-- as the hover trigger (separate key — they're independent features)
local prefetch_token = nil
local last_prefetch_key = nil

-- the open() pipeline in flight before a session exists; a newer open must
-- explicitly abandon it (cancellation is explicit — see async.token)
local open_token = nil

local function cancel_prefetch()
  if prefetch_token then
    require("typescope.async").cancel(prefetch_token)
    prefetch_token = nil
  end
end

-- Throwaway hover at (0,0): the server's initial semantic pass is paid for
-- by the first request it receives, so send a worthless one at attach time —
-- the analysis happens while the user is still reading the file, not when
-- they press K.
local function kick_analysis(bufnr)
  if vim.bo[bufnr].filetype ~= "python" or vim.b[bufnr].typescope_kicked then
    return
  end
  local lsp = require("typescope.lsp")
  local client = lsp.client_for(bufnr)
  if not client then
    return
  end
  vim.b[bufnr].typescope_kicked = true
  lsp.request_cb(
    client,
    "textDocument/hover",
    lsp.position_params(bufnr, 0, 0),
    require("typescope.async").token(),
    function() end
  )
end

--- Front-load the cold-open costs the moment we know we're in a python
--- buffer: server analysis at attach, resolve cache on cursor rest, ollama
--- model at plugin load.
---@param cfg typescope.Config
function M._enable_warmstart(cfg)
  local group = vim.api.nvim_create_augroup("TypeScopeWarmstart", { clear = true })

  -- lazy-loading on FileType python races LspAttach, so sweep buffers that
  -- already have a client, then watch for future attaches
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    desc = "TypeScope: kick server analysis for python buffers",
    callback = function(args)
      kick_analysis(args.buf)
    end,
  })
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      kick_analysis(bufnr)
    end
  end

  -- silent cache warming on cursor rest: run the resolve pipeline with no
  -- float so the eventual K/open paints from the cache. The hover trigger
  -- already does this work (with a float), so prefetch defers to it.
  if cfg.prefetch and cfg.trigger ~= "hover" then
    vim.api.nvim_create_autocmd("CursorHold", {
      group = group,
      desc = "TypeScope: silent cache warming on cursor rest (prefetch)",
      callback = function()
        if vim.bo.filetype ~= "python" or vim.fn.mode() ~= "n" or session then
          return
        end
        local lsp = require("typescope.lsp")
        local client = lsp.client_for(0)
        local cword = vim.fn.expand("<cword>")
        if not client or cword == "" then
          return
        end
        local pos = vim.api.nvim_win_get_cursor(0)
        local key = ("%d:%d:%s"):format(vim.api.nvim_get_current_buf(), pos[1], cword)
        if key == last_prefetch_key then
          return
        end
        last_prefetch_key = key
        cancel_prefetch()
        local async = require("typescope.async")
        local token = async.token()
        prefetch_token = token
        local bufnr = vim.api.nvim_get_current_buf()
        local win = vim.api.nvim_get_current_win()
        async.run(function()
          -- results and errors both discarded: the cache write inside
          -- function_scope is the entire point
          require("typescope.resolve").function_scope(client, bufnr, win, token)
          if prefetch_token == token then
            prefetch_token = nil
          end
        end)
      end,
    })
  end

  -- model (and, with autostart, the server itself) warm before any float
  if cfg.ollama.enabled then
    require("typescope.examples.ollama").warmup(cfg.ollama)
  end
end

--- Close any open TypeScope float and cancel in-flight work.
function M.close()
  if not session then
    return
  end
  local s = session
  session = nil
  require("typescope.async").cancel(s.token)
  require("typescope.examples").on_landed(nil)
  pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
  require("typescope.float").close(s.handle)
end

---@param srcbuf integer
---@param roots typescope.Node[]
---@param meta { header?: string, docstring?: string }?
---@param token typescope.CancelToken
---@param client vim.lsp.Client
---@param sig_result table? signatureHelp result (activeParameter only)
---@param focus boolean enter the float on open (ui.focus for explicit opens; always false for the CursorHold auto-open)
local function show(srcbuf, roots, meta, token, client, sig_result, focus)
  local cfg = require("typescope.config").get()
  -- captured before the float can take focus: with ui.focus the current
  -- window is the float once open, and the hint must mark the source line
  local srccursor = vim.api.nvim_win_get_cursor(0)
  local float = require("typescope.float")
  local render = require("typescope.render")
  local styles = require("typescope.styles")
  local interact = require("typescope.interact")
  local lsp = require("typescope.lsp")
  require("typescope.highlights").apply()

  -- mark the active parameter (cursor inside the call's argument list),
  -- matched by name — see lsp.active_param for why not by index. Cached
  -- trees carry the previous open's flag, so clear before setting.
  local active_name = lsp.active_param(sig_result)
  local header = meta and meta.header or nil
  local active_id = nil -- ledger: the detail block opens on the active param
  if meta and meta.overloads then
    -- overloads (U4): stacked groups — expand the one that matches the
    -- arguments so far, collapse the rest; the active-param flag lives on
    -- that group's children. Header follows the same choice. The server's
    -- activeSignature wins when it says something; 0 is ambiguous
    -- (basedpyright's constant answer), so the written args break the tie
    -- client-side (h8h).
    local server_idx = sig_result and sig_result.activeSignature or 0
    local idx
    if server_idx > 0 then
      idx = math.min(server_idx + 1, meta.overloads)
    else
      local impl = require("typescope.extract").get(vim.bo[srcbuf].filetype)
      local args = impl and impl.call_args and impl.call_args(srcbuf, srccursor[1] - 1, srccursor[2])
      idx = require("typescope.match").pick(roots, args) or 1
    end
    for i, root in ipairs(roots) do
      root.state.expanded = i == idx
      for _, child in ipairs(root.children) do
        child.active = i == idx and child.kind == "param" and child.name == active_name or false
        active_id = child.active and child.id or active_id
      end
    end
    header = meta.headers[idx] .. (" [%d/%d]"):format(idx, meta.overloads)
  else
    for _, root in ipairs(roots) do
      root.active = root.kind == "param" and root.name == active_name or false
      active_id = root.active and root.id or active_id
    end
  end

  local max_width = require("typescope.config").resolved_max_width()
  local render_opts = {
    style = styles.get(cfg.ui.style),
    max_width = max_width,
    layout = cfg.ui.layout,
    align = cfg.ui.align,
    show_examples = cfg.show_examples and cfg.example_mode ~= "none",
    example_kind = cfg.example_mode == "llm" and "llm" or "heuristic",
    lang = vim.bo[srcbuf].filetype,
    -- unified float (U1): call-shape header + docstring section, absorbing
    -- the retired anchor float's content
    header = header,
    header_active = active_name,
    docstring = meta and meta.docstring or nil,
    docstring_expanded = false,
    docstring_pos = cfg.ui.docstring,
    -- ledger: open with the active param's detail showing; interact's
    -- CursorMoved wiring takes over once the float is focused
    detail_id = cfg.ui.layout == "ledger" and active_id or nil,
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
    enter = focus,
  })

  -- land on the active param's primary row: with ui.focus the tree keys are
  -- live immediately, so the cursor should start where the user is typing
  if active_id then
    for lnum = 1, #result.lines do
      if result.line_to_node[lnum] == active_id then
        vim.api.nvim_win_set_cursor(handle.win, { lnum, 0 })
        break
      end
    end
  end

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

  -- LLM batches land asynchronously — this float's own AND late ones from a
  -- previous open whose keys the in-flight dedup skipped (40u). Subscribe as
  -- the single repaint path: copy cached values onto this tree (a fresh-tree
  -- reopen needs the copy; a resolve-cache-shared tree already has them) and
  -- re-render.
  local examples = require("typescope.examples")
  examples.on_landed(function()
    if session and session.handle.win == handle.win and vim.api.nvim_win_is_valid(handle.win) then
      examples.apply_cache(roots)
      ctrl.refresh()
    end
  end)

  -- quiet marker on the call line: TypeScope has data here
  require("typescope.hint").place(srcbuf, srccursor[1] - 1)

  -- pre-load the model in the background so the first E press is warm
  if cfg.ollama.enabled then
    require("typescope.examples.ollama").warmup(cfg.ollama)
  end

  -- example_mode = "llm": generate automatically on open. The float is fully
  -- usable meanwhile (heuristics show immediately); LLM values swap in when
  -- the background request lands. E stays useful for newly expanded leaves.
  if cfg.ollama.enabled and cfg.example_mode == "llm" then
    -- same single-flight machinery as the E keymap (spinner, progress,
    -- refresh); only the error policy differs: warn once per nvim session
    ctrl.generate(function(err)
      if not llm_auto_warned then
        llm_auto_warned = true
        vim.notify("typescope: auto LLM examples unavailable — " .. err, vim.log.levels.WARN)
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
        if session and session.handle.win == handle.win and vim.api.nvim_get_current_win() ~= handle.win then
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
--- function, plain builtin hover otherwise. With ui.focus (default) the
--- float opens already focused; with focus = false this keeps the builtin
--- double-K convention (first K opens, second K focuses).
function M.hover()
  if session and vim.api.nvim_win_is_valid(session.handle.win) then
    vim.wo[session.handle.win].cursorline = true
    vim.api.nvim_set_current_win(session.handle.win)
    return
  end
  M.open({
    silent = true,
    on_unresolved = function(reason, why)
      vim.lsp.buf.hover()
      -- "absent" means there was nothing here for TypeScope — a variable, a
      -- keyword, a non-Python buffer. Silence is correct: this is bound to K,
      -- and announcing itself on every miss would make it unusable.
      --
      -- "empty" is different in kind. TypeScope found the function, understood
      -- it, and DECIDED there was nothing to draw (no parameters, no return
      -- annotation). Without this line that decision is invisible, and a
      -- deliberate decline looks identical to never having run — which is
      -- exactly what a receiver-only method like `def m(self)` produces.
      --
      -- Echoed, not notified: the message line clears itself on the next
      -- keystroke, where a notification would stack up behind a key you press
      -- all day.
      if why == "empty" and reason then
        vim.api.nvim_echo({ { "typescope: " .. reason, "Comment" } }, false, {})
      end
    end,
  })
end

--- Open the TypeScope float for the function under the cursor; if already
--- open, focus it (arming the tree keymaps).
---@param opts? { silent?: boolean, on_unresolved?: fun(reason: string?, why: string?), focus?: boolean } silent: no notifications (hover trigger); on_unresolved: called instead when the pipeline can't produce a tree, with the reason and its kind ("stale"|"absent"|"empty"); focus: override ui.focus for this open
function M.open(opts)
  opts = opts or {}
  if session and vim.api.nvim_win_is_valid(session.handle.win) then
    vim.wo[session.handle.win].cursorline = true
    vim.api.nvim_set_current_win(session.handle.win)
    return
  end
  M.close()
  cancel_prefetch() -- the real pipeline supersedes any in-flight warming
  if open_token then
    require("typescope.async").cancel(open_token)
  end

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
  open_token = token
  async.run(function()
    local resolve = require("typescope.resolve")
    local roots, meta_or_err, why = resolve.function_scope(client, bufnr, win, token)
    if async.stale(token) then
      return
    end
    if not roots then
      if opts.on_unresolved then
        opts.on_unresolved(meta_or_err, why)
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
    local focus = opts.focus
    if focus == nil then
      focus = require("typescope.config").get().ui.focus
    end
    show(bufnr, roots, meta_or_err, token, client, sig_result, focus)
    if open_token == token then
      open_token = nil -- pipeline done; the session owns the token now
    end
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
