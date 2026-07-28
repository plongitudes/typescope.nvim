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

--- Structural resolution came up empty for this node (alias, TypeVar,
--- unresolvable name): ask the evaluated universe instead. Hovers the refs in
--- order and keeps the first *informative* answer — a hover that merely
--- echoes the name back (a class behind the typeshed guard says "(class)
--- Protocol") decorates nothing, but an alias expansion does.
---@param ctx typescope.ResolveCtx
---@param node typescope.Node
---@param src_buf integer
---@param refs table[] annotation refs
local function evaluate_leaf(ctx, node, src_buf, refs)
  for i = 1, math.min(#refs, 3) do
    local ref = refs[i]
    local lines = lsp.hover_lines(ctx.client, src_buf, ref.row, ref.col, ctx.token)
    if async.stale(ctx.token) then
      return
    end
    local evaluated = lines and ctx.impl.evaluated_from_hover(lines, ref.name)
    if
      evaluated
      and evaluated ~= node.type.display
      and evaluated ~= ref.name
      and evaluated ~= ref.name:match("[%w_]+$")
    then
      node.evaluated = evaluated
      return
    end
  end
end

-- attach_type and populate_from_class are mutually recursive
local attach_type
local populate_from_class

--- Fill `target` with a resolved class's fields (own first, then inherited —
--- child overrides win, inherited entries tagged with their origin class:
--- Tony's origin-badge presentation, 2026-07-27) and methods.
---@param ctx typescope.ResolveCtx
---@param target typescope.Node
---@param cls table extractor result
---@param tbuf integer buffer the class lives in
---@param depth integer
---@param sub_ancestry table<string, true> cycle guard including this class
populate_from_class = function(ctx, target, cls, tbuf, depth, sub_ancestry)
  local cfg = config.get()

  local entries = {}
  local seen_names = {}
  for _, f in ipairs(cls.fields) do
    seen_names[f.name] = true
    table.insert(entries, { f = f, buf = tbuf })
  end
  local function walk_bases(c, cbuf, base_ancestry, level)
    if level > 3 then
      return -- inheritance chains deeper than this are their own problem
    end
    for _, base in ipairs(c.bases or {}) do
      if async.stale(ctx.token) then
        return
      end
      local bloc = lsp.definition(ctx.client, cbuf, base.row, base.col, ctx.token)
      if bloc and not base_ancestry[loc_key(bloc)] then
        local bcls, bbuf, brealloc = class_at_location(ctx, bloc, 0)
        if bcls then
          -- UserCreate(UserBase) classifies as plain "class" — only the
          -- parent names BaseModel. Adopt the parent's construct category.
          if cls.category == "class" and bcls.category ~= "class" then
            cls.category = bcls.category
            target.type.category = bcls.category
          end
          local next_ancestry =
            vim.tbl_extend("force", {}, base_ancestry, { [loc_key(brealloc)] = true })
          for _, f in ipairs(bcls.fields) do
            if not seen_names[f.name] then
              seen_names[f.name] = true
              table.insert(entries, { f = f, buf = bbuf, origin = bcls.class_name })
            end
          end
          walk_bases(bcls, bbuf, next_ancestry, level + 1)
        end
      end
    end
  end
  walk_bases(cls, tbuf, sub_ancestry, 1)

  for _, entry in ipairs(entries) do
    local f, fbuf = entry.f, entry.buf
    local ann = f.type_node and ctx.impl.annotation(fbuf, f.type_node)
    local child = model.new({
      name = f.name,
      kind = "field",
      type = ann and type_info(ann.display, ann.refs) or nil,
      default = f.default,
      badge = f.badge,
      origin = entry.origin,
    })
    if ann and #ann.refs > 0 then
      if depth < cfg.depth then
        attach_type(ctx, child, fbuf, ann.refs, depth + 1, sub_ancestry)
        if async.stale(ctx.token) then
          return
        end
      else
        -- beyond depth: leave a lazy hook for `r` / expand
        child.state.loaded = false
        child.source = {
          uri = vim.uri_from_bufnr(fbuf),
          range = { start = { line = ann.refs[1].row, character = 0 } },
        }
        child._lazy = {
          uri = vim.uri_from_bufnr(fbuf),
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
---@param force_single? boolean treat a lone ref as covering the whole node (alias transparency)
attach_type = function(ctx, node, src_buf, refs, depth, ancestry, force_single)
  local single = (force_single and #refs == 1) or (#refs == 1 and node.type.display == refs[1].name)
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
      populate_from_class(ctx, target, cls, tbuf, depth, sub_ancestry)
      if async.stale(ctx.token) then
        return
      end
      if not single and #target.children > 0 then
        model.add_child(node, target)
      end
    elseif loc and not ancestry[loc_key(loc)] and not is_typeshed(loc.uri) then
      -- alias hop: definition landed on `X = SomeClass` / `X = A | B` — parse
      -- the RHS as an annotation and chase through it transparently, keeping
      -- the alias name as the displayed vocabulary
      local abuf = lsp.load_buf(loc.uri)
      local arow, acol = lsp.range_start(abuf, loc.range)
      local rhs = ctx.impl.alias_at(abuf, arow, acol)
      local alias_ann = rhs and ctx.impl.annotation(abuf, rhs)
      if alias_ann and #alias_ann.refs > 0 then
        local alias_ancestry = vim.tbl_extend("force", {}, ancestry, { [loc_key(loc)] = true })
        local target = single and node
          or model.new({
            name = ref.name,
            kind = "variant",
            type = { raw = ref.name, display = ref.name, category = "generic" },
          })
        attach_type(ctx, target, abuf, alias_ann.refs, depth, alias_ancestry, #alias_ann.refs == 1)
        if async.stale(ctx.token) then
          return
        end
        if not single and #target.children > 0 then
          model.add_child(node, target)
        end
      end
    end
  end
  -- every ref failed structurally (alias, TypeVar, unresolvable): decorate
  -- the leaf with pyright's evaluated view instead of leaving a dead end
  if #node.children == 0 and #refs > 0 and not node._lazy then
    evaluate_leaf(ctx, node, src_buf, refs)
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
    -- A class under the cursor is the most TypeScope-shaped thing there is:
    -- show the type's own structure directly (class_at_location handles the
    -- import hop and the typeshed guard, so `str` won't explode here).
    local cls, tbuf, realloc = class_at_location(ctx, loc, 0)
    if cls and (#cls.fields > 0 or #cls.methods > 0 or #(cls.bases or {}) > 0) then
      local root = model.new({
        name = cls.class_name,
        kind = "type",
        expanded = true,
        type = {
          raw = cls.class_name,
          display = "(" .. cls.category .. ")",
          category = cls.category,
        },
      })
      populate_from_class(ctx, root, cls, tbuf, 1, { [loc_key(realloc)] = true })
      if async.stale(token) then
        return nil, "stale"
      end
      if #root.children > 0 then
        -- category may have been corrected by the base walk (UserCreate case)
        root.type.display = "(" .. cls.category .. ")"
        require("typescope.examples").annotate({ root })
        return { root }
      end
    end

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
    return nil, "symbol does not resolve to a function definition or class"
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
    elseif not p.type_node and p.name_row then
      -- unannotated param: pyright still infers a type — hover the name
      local lines = lsp.hover_lines(client, fbuf, p.name_row, p.name_col, token)
      if async.stale(token) then
        return nil, "stale"
      end
      local evaluated = lines and impl.evaluated_from_hover(lines, p.name)
      if evaluated and evaluated ~= "Any" then
        node.evaluated = evaluated
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
