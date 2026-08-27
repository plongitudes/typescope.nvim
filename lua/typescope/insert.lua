-- Insert-mode typing surface (U6): ONE line for the active parameter,
-- repositioned every keystroke so the cursor line and the line below it are
-- never occluded. No tree, no docstring, no LLM, no keymaps — the density
-- research's insert rule is "zero manual controls": segments drop in a fixed
-- order (example → default → type truncation) as width shrinks, and the
-- active param follows signatureHelp silently (overload auto-follow included).

local M = {}

---@class typescope.InsertState
---@field handle typescope.FloatHandle
---@field key string call identity (buf + call node start)
---@field srcbuf integer
---@field roots typescope.Node[] full resolve result (all overload groups)
---@field meta table? resolve meta (headers/overloads for auto-follow)
---@field overload_idx integer? currently followed overload
---@field fn_name string? callee name shown as trailing context
---@field token typescope.CancelToken
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
        -- strictly < ecol: ecol is the position AFTER the closing paren, and
        -- an insert cursor sitting there is OUTSIDE the call — the surface
        -- must not fire (Tony's report); the walk continues to any outer call
        local before_close = row0 < erow or (row0 == erow and col < ecol)
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
---@return typescope.Node[]
local function active_params(st)
  if st.meta then
    return st.roots[st.overload_idx].children
  end
  return st.roots
end

-- The one param the typing surface describes: signatureHelp's active param by name,
-- else the first param (a fresh `f(` before any answer lands).
---@param st typescope.InsertState
---@return typescope.Node?
local function param_node(st)
  local first = nil
  for _, node in ipairs(active_params(st)) do
    if node.kind == "param" then
      first = first or node
      if st.active_name and node.name == st.active_name then
        return node
      end
    end
  end
  return first
end

---@param st typescope.InsertState
---@return typescope.RenderResult?
local function typing_result(st)
  local node = param_node(st)
  if not node then
    return nil
  end
  -- signature block: every viable param of the active overload (current one
  -- lit) plus its return type, K-header style
  local params = {}
  local ret = nil
  for _, p in ipairs(active_params(st)) do
    if p.kind == "param" then
      table.insert(params, { name = p.name, active = p == node })
    elseif p.kind == "return" then
      ret = p.type.display
    end
  end
  local config = require("typescope.config")
  local cfg = config.get()
  return require("typescope.render").typing_surface(node, {
    max_width = math.min(config.resolved_max_width(cfg.insert_mode.max_width), vim.o.columns - 6),
    max_detail_lines = cfg.insert_mode.max_detail_lines,
    show_examples = cfg.show_examples and cfg.example_mode ~= "none",
    example_kind = "heuristic", -- LLM values decorate if already cached, never requested
    style = require("typescope.styles").get(cfg.ui.style),
    fn_name = st.fn_name,
    ret = ret,
    badge = st.meta and ("[%d/%d]"):format(st.overload_idx, st.meta.overloads) or nil,
    params = params,
  })
end

-- Hard rule (density research): the cursor line and the line BELOW it are
-- never occluded. The bordered float sits above the cursor, growing UPWARD
-- as the names block wraps (SW anchor pins the bottom edge); when there
-- isn't room, below the line under the cursor is the only legal spot.
---@param height integer content rows
---@return table win config fragment (relative/anchor/row/col)
local function placement(height)
  local above = vim.fn.winline() > height + 2
  return {
    relative = "cursor",
    anchor = above and "SW" or "NW",
    -- REAL-UI semantics (hard-won: headless nvim attaches no UI and never
    -- applies anchor geometry, so headless position probes LIE — they show
    -- raw NW placement; Tony's screenshots were the ground truth): the
    -- anchored extent INCLUDES the border. SW row 0 → bottom border on the
    -- line above the cursor, growing upward; NW row 2 → top border on
    -- cursor+2, keeping the line below the cursor clear.
    row = above and 0 or 2,
    col = 0,
  }
end

-- The active param's shape (valid values / union expansion) may be behind a
-- _lazy hook (typeshed alias — open()'s OpenTextMode). Fetch just the ≈ view
-- on demand: one hover, cached on the shared node, structure untouched.
-- Pending state is the token itself, so a cancelled fetch can retry later.
local repaint
---@param st typescope.InsertState
local function ensure_shape(st)
  local node = param_node(st)
  local async = require("typescope.async")
  if not node or node.evaluated or not node._lazy then
    return
  end
  if node._eval_pending and not async.stale(node._eval_pending) then
    return
  end
  local client = require("typescope.lsp").client_for(st.srcbuf)
  if not client then
    return
  end
  node._eval_pending = st.token
  require("typescope.resolve").evaluate(client, node, st.token, function(filled)
    node._eval_pending = nil
    if filled and state == st then
      repaint(st)
    end
  end)
end

-- Re-pin the open float to the current cursor screen position (cursor-
-- relative floats anchor once; they don't follow view changes on their own).
local function reanchor()
  if state and vim.api.nvim_win_is_valid(state.handle.win) then
    vim.api.nvim_win_set_config(state.handle.win, placement(vim.api.nvim_win_get_height(state.handle.win)))
  end
end

---@param st typescope.InsertState
repaint = function(st)
  ensure_shape(st)
  local result = typing_result(st)
  if not result then
    close_float() -- an overload swap can land on a 0-param signature
    return
  end
  require("typescope.float").update(st.handle, {
    lines = result.lines,
    highlights = result.highlights,
    ts_injections = result.ts_injections,
    lang = vim.bo[st.srcbuf].filetype,
    width = result.width,
    height = #result.lines,
  })
  vim.api.nvim_win_set_config(st.handle.win, placement(#result.lines))
end

-- Debounced signatureHelp → active param + (U4) overload auto-follow: when
-- activeSignature changes, the typing surface silently swaps to that overload.
-- Repaints only on change; no resolve, no chases.
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
        if st.meta and st.meta.overloads then
          -- a nonzero activeSignature is a real server answer and wins; 0 or
          -- no answer at all (basedpyright: inside string arguments) are both
          -- ambiguous — match the written args client-side (h8h). A nil pick
          -- keeps the current overload, so the display never snaps back to 1.
          local server_idx = ok_result and ok_result.activeSignature or 0
          local idx
          if server_idx > 0 then
            idx = math.min(server_idx + 1, st.meta.overloads)
          else
            local impl = require("typescope.extract").get(vim.bo[st.srcbuf].filetype)
            local args = impl and impl.call_args and impl.call_args(st.srcbuf, pos[1] - 1, pos[2])
            idx = require("typescope.match").pick(st.roots, args) or st.overload_idx
          end
          if idx ~= st.overload_idx then
            st.overload_idx = idx
            changed = true
          end
        end
        local name = lsp.active_param(ok_result)
        if name ~= st.active_name then
          st.active_name = name
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

    local has_overloads = type(meta) == "table" and meta.overloads ~= nil
    ---@type typescope.InsertState
    local st = {
      handle = nil, -- set below; typing_result doesn't need it
      key = key,
      srcbuf = srcbuf,
      roots = roots,
      meta = has_overloads and meta or nil,
      overload_idx = has_overloads and 1 or nil,
      fn_name = type(meta) == "table" and meta.header and meta.header:match("^[%w_]+") or nil,
      token = token,
      active_name = nil,
    }
    local result = typing_result(st)
    if not result then
      return -- nothing to describe (0-param call); pending_key stays as negative cache
    end
    pending_key = nil

    -- same as the reading float's show(): the TypeScope* groups only exist
    -- after apply() — without this, an insert float opened before any K
    -- press painted colorless
    require("typescope.highlights").apply()
    local pos = placement(#result.lines)
    st.handle = require("typescope.float").open({
      lines = result.lines,
      highlights = result.highlights,
      ts_injections = result.ts_injections,
      lang = vim.bo[srcbuf].filetype,
      title = " typescope ",
      relative = pos.relative,
      anchor = pos.anchor,
      row = pos.row,
      col = pos.col,
      width = result.width,
      height = #result.lines,
      border = require("typescope.config").get().ui.border, -- same frame as the K float (Tony: ui consistency)
      enter = false,
      focusable = false,
    })
    state = st
    ensure_shape(st)
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
    -- same call: keep the hard no-occlusion rule true as the cursor moves
    -- (a wrapped call can walk the cursor toward a below-anchored float)
    reanchor()
    refresh_active()
    return
  end
  if pending_key == key then
    return -- resolve in flight (or this call already failed once)
  end
  open_for(bufnr, key, frow0, fcol)
end

--- Register or tear down the typing-surface autocmds. Takes the flag rather
--- than being called conditionally, so the off case cannot be forgotten: the
--- group is cleared either way, and turning the feature off also closes a
--- surface that happens to be open — a float belonging to a disabled feature
--- has no business outliving it.
---@param enabled boolean
function M.set_enabled(enabled)
  local group = vim.api.nvim_create_augroup("TypeScopeInsert", { clear = true })
  if not enabled then
    M.close()
    return
  end
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
  -- a view scroll without a cursor move (autopairs growing the file at the
  -- window edge, scrolloff shifts) fires no CursorMovedI — re-pin so the
  -- float never drifts away from (or onto) the cursor line
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    desc = "TypeScope: typing surface follows view scrolls",
    callback = reanchor,
  })
end

return M
