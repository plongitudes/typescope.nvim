-- Insert-mode typing surface (U3): a budget-reduced unified float following
-- the call under the cursor while typing. The reading surface's rules don't
-- apply here — never focusable, no docstring, no LLM, no tree interaction:
-- header + collapsed roots + heuristic examples, painted from the resolve
-- cache whenever it's warm (prefetch usually made it so).

local M = {}

---@class typescope.InsertState
---@field handle typescope.FloatHandle
---@field key string call identity (buf + call node start)
---@field srcbuf integer
---@field display typescope.Node[] shallow root clones (fold/active state stays ours)
---@field roots typescope.Node[] full resolve result (all overload groups)
---@field meta table? resolve meta (headers/overloads for auto-follow)
---@field overload_idx integer? currently displayed overload
---@field opts table render opts
---@field token typescope.CancelToken
---@field width integer
---@field active_name string?

---@type typescope.InsertState?
local state = nil
-- call currently resolving (float not open yet); also a negative cache: a
-- call that failed to resolve isn't retried on every keystroke
local pending_key = nil
local resolve_token = nil
local sig_timer = nil

local function stop_timer()
  if sig_timer then
    sig_timer:stop()
    sig_timer:close()
    sig_timer = nil
  end
end

-- close the float without cancelling an in-flight resolve (open_for manages
-- resolve_token itself)
local function close_float()
  stop_timer()
  if state then
    require("typescope.float").close(state.handle)
    state = nil
  end
end

--- Close the typing surface and abandon any in-flight work.
function M.close()
  close_float()
  pending_key = nil
  if resolve_token then
    require("typescope.async").cancel(resolve_token)
    resolve_token = nil
  end
end

--- Innermost call whose argument list contains the cursor, plus the callee
--- position to resolve (rightmost identifier: `run` of `uvicorn.run`).
--- NOTE: an unclosed `f(` may not parse as a call node yet — with auto-pairs
--- (the common setup) the closing paren exists and this is a non-issue; if
--- bare `(` proves important, supplement with the server's trigger chars.
---@param bufnr integer
---@param row0 integer 0-based cursor row
---@param col integer byte col
---@return TSNode? call, integer? frow0, integer? fcol
local function call_at_cursor(bufnr, row0, col)
  local ok = pcall(function()
    vim.treesitter.get_parser(bufnr):parse()
  end)
  if not ok then
    return
  end
  -- the char just typed sits at col-1; the insertion point itself can land
  -- on the token after the cursor
  local nok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row0, math.max(0, col - 1) } })
  if not nok then
    return
  end
  while node do
    if node:type() == "call" then
      local args = node:field("arguments")[1]
      if args then
        local srow, scol, erow, ecol = args:range()
        local after_open = row0 > srow or (row0 == srow and col > scol)
        local before_close = row0 < erow or (row0 == erow and col <= ecol)
        if after_open and before_close then
          local fn = node:field("function")[1]
          if fn then
            if fn:type() == "attribute" then
              fn = fn:field("attribute")[1] or fn
            end
            local frow, fcol = fn:range()
            return node, frow, fcol
          end
        end
      end
    end
    node = node:parent()
  end
end

---@param st typescope.InsertState
local function repaint(st)
  local render = require("typescope.render")
  local result = render.render(st.display, st.opts)
  require("typescope.float").update(st.handle, {
    lines = result.lines,
    highlights = result.highlights,
    ts_injections = result.ts_injections,
    lang = st.opts.lang,
    width = st.width,
    height = math.min(require("typescope.config").get().ui.max_height, #result.lines),
  })
end

-- shallow clones with their OWN state tables: the cached tree's fold state
-- belongs to the reading surface; the typing surface always shows collapsed
-- roots and must not clobber K's folds
local function clone_roots(source)
  local display = {}
  for _, root in ipairs(source) do
    local copy = vim.tbl_extend("force", {}, root)
    copy.state = { expanded = false, loaded = root.state.loaded, loading = false }
    copy.active = false
    table.insert(display, copy)
  end
  return display
end

---@param meta table
---@param idx integer
local function overload_header(meta, idx)
  return meta.headers[idx] .. (" [%d/%d]"):format(idx, meta.overloads)
end

-- Debounced signatureHelp → active-param row highlight, and (U4) overload
-- auto-follow: when activeSignature changes, the display silently swaps to
-- that overload's params. Repaints only on change; no resolve, no chases.
local function refresh_active()
  stop_timer()
  sig_timer = vim.uv.new_timer()
  sig_timer:start(
    80,
    0,
    vim.schedule_wrap(function()
      stop_timer()
      local st = state
      if not st then
        return
      end
      local lsp = require("typescope.lsp")
      local client = lsp.client_for(st.srcbuf)
      if not client then
        return
      end
      local pos = vim.api.nvim_win_get_cursor(0)
      local params = lsp.position_params(st.srcbuf, pos[1] - 1, pos[2])
      lsp.request_cb(client, "textDocument/signatureHelp", params, st.token, function(err, result)
        if err or state ~= st then
          return
        end
        local ok_result = result and result.signatures and #result.signatures > 0 and result or nil
        local changed = false
        -- follow only on a real answer: servers return nil at some positions
        -- (basedpyright: inside string arguments) and that must not snap the
        -- display back to overload 1
        if st.meta and st.meta.overloads and ok_result then
          local idx = math.min((ok_result.activeSignature or 0) + 1, st.meta.overloads)
          if idx ~= st.overload_idx then
            st.overload_idx = idx
            st.display = clone_roots(st.roots[idx].children)
            st.opts.header = overload_header(st.meta, idx)
            st.active_name = nil
            changed = true
          end
        end
        local name = lsp.active_param(ok_result)
        if name ~= st.active_name then
          st.active_name = name
          for _, root in ipairs(st.display) do
            root.active = root.kind == "param" and root.name == name or false
          end
          changed = true
        end
        if changed then
          repaint(st)
        end
      end)
    end)
  )
end

---@param srcbuf integer
---@param key string
---@param frow0 integer callee 0-based row
---@param fcol integer callee byte col
local function open_for(srcbuf, key, frow0, fcol)
  close_float()
  pending_key = key
  local async = require("typescope.async")
  if resolve_token then
    async.cancel(resolve_token)
  end
  local token = async.token()
  resolve_token = token
  local win = vim.api.nvim_get_current_win()
  local client = require("typescope.lsp").client_for(srcbuf)
  if not client then
    return
  end
  async.run(function()
    local roots, meta = require("typescope.resolve").function_scope(client, srcbuf, win, token, { frow0 + 1, fcol })
    if async.stale(token) or pending_key ~= key then
      return
    end
    if not roots then
      return -- typing surface never nags; pending_key stays as negative cache
    end
    pending_key = nil

    -- overloads (U4): the typing surface never stacks — it shows the active
    -- overload's params only and swaps silently as activeSignature moves
    local has_overloads = type(meta) == "table" and meta.overloads ~= nil
    local display = clone_roots(has_overloads and roots[1].children or roots)

    local config = require("typescope.config")
    local cfg = config.get()
    local opts = {
      style = require("typescope.styles").get(cfg.ui.style),
      max_width = config.resolved_max_width(),
      layout = cfg.ui.layout,
      align = cfg.ui.align,
      show_examples = cfg.show_examples and cfg.example_mode ~= "none",
      example_kind = "heuristic", -- LLM values decorate if already cached, never requested
      lang = vim.bo[srcbuf].filetype,
      header = has_overloads and overload_header(meta, 1) or (type(meta) == "table" and meta.header or nil),
      docstring = nil, -- no prose while typing
      docstring_pos = false,
    }
    local result = require("typescope.render").render(display, opts)
    local width = math.min(opts.max_width, math.max(result.width, 30))
    local height = math.min(cfg.ui.max_height, #result.lines)

    -- signature-help convention: sit above the cursor line when there's
    -- room (never cover what's being typed), below otherwise
    local above = vim.fn.winline() - 1 > height + 2
    local handle = require("typescope.float").open({
      lines = result.lines,
      highlights = result.highlights,
      ts_injections = result.ts_injections,
      lang = opts.lang,
      title = " typescope ",
      relative = "cursor",
      anchor = above and "SW" or "NW",
      row = above and 0 or 1,
      col = 0,
      width = width,
      height = height,
      border = cfg.ui.border,
      enter = false,
      focusable = false,
    })
    state = {
      handle = handle,
      key = key,
      srcbuf = srcbuf,
      display = display,
      roots = roots,
      meta = has_overloads and meta or nil,
      overload_idx = has_overloads and 1 or nil,
      opts = opts,
      token = token,
      width = width,
      active_name = nil,
    }
    refresh_active()
  end)
end

--- Per-keystroke entry (TextChangedI / CursorMovedI / InsertEnter). No mode
--- check anywhere in this module: the trigger events are insert-only, and
--- leaving insert mid-resolve is handled by InsertLeave → close → token
--- cancellation, not by re-checking the mode after the fact.
function M._update()
  local cfg = require("typescope.config").get()
  if not cfg.insert_mode.enabled then
    return
  end
  if vim.bo.filetype ~= "python" then
    M.close()
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local call, frow0, fcol = call_at_cursor(bufnr, pos[1] - 1, pos[2])
  if not call then
    M.close()
    return
  end
  local srow, scol = call:range()
  local key = ("%d:%d:%d"):format(bufnr, srow, scol)
  if state and state.key == key then
    refresh_active()
    return
  end
  if pending_key == key then
    return -- resolve in flight (or this call already failed once)
  end
  open_for(bufnr, key, frow0, fcol)
end

--- Register the typing-surface autocmds (called from setup when enabled).
function M.enable()
  local group = vim.api.nvim_create_augroup("TypeScopeInsert", { clear = true })
  vim.api.nvim_create_autocmd({ "InsertEnter", "TextChangedI", "CursorMovedI" }, {
    group = group,
    desc = "TypeScope: typing surface follows the call under the cursor",
    callback = function()
      M._update()
    end,
  })
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = group,
    desc = "TypeScope: typing surface closes with insert mode",
    callback = function()
      M.close()
    end,
  })
end

return M
