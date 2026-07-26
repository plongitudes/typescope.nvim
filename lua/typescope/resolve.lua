-- Pipeline orchestrator: definition of the function under the cursor →
-- TreeSitter signature parse → per-type definition chase → field extraction,
-- recursing to config.depth with cycle + typeshed guards. All functions that
-- await must run inside async.run; every await point re-checks the token.

local async = require("typescope.async")
local lsp = require("typescope.lsp")
local model = require("typescope.model")
local config = require("typescope.config")
local extract = require("typescope.extract")

local M = {}

---@class typescope.ResolveCtx
---@field client vim.lsp.Client
---@field token typescope.CancelToken
---@field impl table language extractor

local function loc_key(loc)
  return loc.uri .. "#" .. loc.range.start.line
end

-- Terminal library boundary: never recurse into typeshed stubs or the
-- runtime stdlib (definition is a runtime question, so TextIO lands in
-- typing.py — stdlib but not "typeshed"). site-packages stays recursable:
-- that's where user-facing models (pydantic etc.) live.
local function is_typeshed(uri)
  if uri:find("typeshed", 1, true) then
    return true
  end
  return uri:find("/lib/python[%d%.]+/") ~= nil and not uri:find("site-packages", 1, true)
end

--- Resolve a location to a classified type, hopping one aliased/`TYPE_CHECKING`
--- import if definition landed on the import statement instead of the class.
---@param ctx typescope.ResolveCtx
---@return table? cls, integer? bufnr, table? loc
local function class_at_location(ctx, loc, hops)
  if is_typeshed(loc.uri) then
    return nil
  end
  local bufnr = lsp.load_buf(loc.uri)
  local row, col = lsp.range_start(bufnr, loc.range)
  local cls, marker = ctx.impl.type_at(bufnr, row, col)
  if cls then
    return cls, bufnr, loc
  end
  if marker == "import" and hops < 1 then
    local hop = lsp.definition(ctx.client, bufnr, row, col, ctx.token)
    if hop and loc_key(hop) ~= loc_key(loc) then
      return class_at_location(ctx, hop, hops + 1)
    end
  end
  return nil
end

---@param refs table[] annotation refs
---@return table type info for a node whose annotation these refs came from
local function type_info(display, refs)
  return {
    raw = display,
    display = display,
    category = #refs > 0 and "generic" or "builtin",
  }
end

--- Chase each user-type ref in an annotation and attach the results to
--- `node`. Single ref covering the whole annotation → fields attach directly
--- (the common `config: ServerConfig` case); otherwise each resolved type
--- becomes a named child (unions, generics with user types inside).
---@param ctx typescope.ResolveCtx
---@param node typescope.Node
---@param src_buf integer buffer the refs' positions live in
---@param depth integer 1 = fields of a param's type
---@param ancestry table<string, true> loc_keys on the current path (cycle guard)
local function attach_type(ctx, node, src_buf, refs, depth, ancestry)
  local cfg = config.get()
  local single = #refs == 1 and node.type.display == refs[1].name
  for _, ref in ipairs(refs) do
    if async.stale(ctx.token) then
      return
    end
    local loc = lsp.definition(ctx.client, src_buf, ref.row, ref.col, ctx.token)
    local cls, tbuf, realloc
    if loc and not ancestry[loc_key(loc)] and not async.stale(ctx.token) then
      cls, tbuf, realloc = class_at_location(ctx, loc, 0)
    end
    if cls then
      local target
      if single then
        target = node
        node.type.category = cls.category
      else
        target = model.new({
          name = ref.name,
          kind = "variant",
          type = { raw = ref.name, display = ref.name, category = cls.category },
        })
      end
      local sub_ancestry = vim.tbl_extend("force", {}, ancestry, { [loc_key(realloc)] = true })
      for _, f in ipairs(cls.fields) do
        local ann = f.type_node and ctx.impl.annotation(tbuf, f.type_node)
        local child = model.new({
          name = f.name,
          kind = "field",
          type = ann and type_info(ann.display, ann.refs) or nil,
          default = f.default,
          badge = f.badge,
        })
        if ann and #ann.refs > 0 then
          if depth < cfg.depth then
            attach_type(ctx, child, tbuf, ann.refs, depth + 1, sub_ancestry)
            if async.stale(ctx.token) then
              return
            end
          else
            -- beyond depth: leave a lazy hook for `r` / expand
            child.state.loaded = false
            child.source = {
              uri = vim.uri_from_bufnr(tbuf),
              range = { start = { line = ann.refs[1].row, character = 0 } },
            }
            child._lazy = {
              uri = vim.uri_from_bufnr(tbuf),
              refs = ann.refs,
              ancestry = sub_ancestry,
              impl = ctx.impl, -- carry the language impl; never re-guess from a hardcoded name
            }
          end
        end
        model.add_child(target, child)
      end
      for _, m in ipairs(cls.methods or {}) do
        model.add_child(
          target,
          model.new({
            name = m.name,
            kind = "method",
            type = { raw = m.signature, display = m.signature, category = "builtin" },
          })
        )
      end
      if not single and #target.children > 0 then
        model.add_child(node, target)
      end
    end
  end
end

--- Full pipeline for the function under the cursor. Coroutine context only.
---@param client vim.lsp.Client
---@param bufnr integer source buffer
---@param win integer source window (cursor position)
---@param token typescope.CancelToken
---@return typescope.Node[]? roots, string? err
function M.function_scope(client, bufnr, win, token)
  local ft = vim.bo[bufnr].filetype
  local impl = extract.get(ft)
  if not impl then
    return nil, ("no extractor for filetype %q"):format(ft)
  end
  local ctx = { client = client, token = token, impl = impl }

  local pos = vim.api.nvim_win_get_cursor(win)
  local loc = lsp.definition(client, bufnr, pos[1] - 1, pos[2], token)
  if async.stale(token) then
    return nil, "stale"
  end
  if not loc then
    return nil, "no definition found for symbol under cursor"
  end

  local fbuf = lsp.load_buf(loc.uri)
  local frow, fcol = lsp.range_start(fbuf, loc.range)
  local info = impl.function_info(fbuf, frow, fcol)
  if not info then
    -- Definition is a *runtime* question and may land on an alias assignment
    -- (stdlib getpass = unix_getpass). Declaration asks the static universe:
    -- for basedpyright that's the typeshed stub, whose annotated `def` parses
    -- through the exact same path.
    local decl = lsp.locate(client, bufnr, pos[1] - 1, pos[2], token, "textDocument/declaration")
    if async.stale(token) then
      return nil, "stale"
    end
    if decl and loc_key(decl) ~= loc_key(loc) then
      fbuf = lsp.load_buf(decl.uri)
      frow, fcol = lsp.range_start(fbuf, decl.range)
      info = impl.function_info(fbuf, frow, fcol)
    end
  end
  if not info then
    return nil, "symbol does not resolve to a function definition"
  end

  local roots = {}
  for _, p in ipairs(info.params) do
    local ann = p.type_node and impl.annotation(fbuf, p.type_node)
    local node = model.new({
      name = p.name,
      kind = "param",
      -- unannotated params are implicitly Any to the type checker
      type = ann and type_info(ann.display, ann.refs) or { raw = "Any", display = "Any", category = "builtin" },
      default = p.default,
    })
    if ann and #ann.refs > 0 then
      attach_type(ctx, node, fbuf, ann.refs, 1, {})
      if async.stale(token) then
        return nil, "stale"
      end
    end
    -- auto-expand policy (v1): params with resolved structure start open,
    -- everything deeper starts closed
    node.state.expanded = #node.children > 0
    table.insert(roots, node)
  end

  if info.return_type then
    local ann = impl.annotation(fbuf, info.return_type)
    local node = model.new({
      name = "returns",
      kind = "return",
      type = type_info(ann.display, ann.refs),
    })
    if #ann.refs > 0 then
      attach_type(ctx, node, fbuf, ann.refs, 1, {})
      if async.stale(token) then
        return nil, "stale"
      end
    end
    table.insert(roots, node)
  end

  if #roots == 0 then
    return nil, ("%s has no parameters or return annotation"):format(info.name)
  end
  require("typescope.examples").annotate(roots)
  return roots
end

--- Lazily resolve a beyond-depth node (the `r` keymap / expanding an
--- unloaded node). Runs its own coroutine; cb fires on success.
---@param client vim.lsp.Client
---@param node typescope.Node
---@param token typescope.CancelToken
---@param cb fun()
function M.recurse(client, node, token, cb)
  local lazy = node._lazy
  if not lazy or node.state.loading then
    return
  end
  node.state.loading = true
  async.run(function()
    local ctx = { client = client, token = token, impl = lazy.impl }
    local bufnr = lsp.load_buf(lazy.uri)
    attach_type(ctx, node, bufnr, lazy.refs, 1, lazy.ancestry or {})
    node.state.loading = false
    if async.stale(token) then
      return
    end
    node.state.loaded = true
    node._lazy = nil
    node.state.expanded = #node.children > 0
    require("typescope.examples").annotate({ node })
    cb()
  end)
end

return M
