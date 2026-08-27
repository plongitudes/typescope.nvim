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

-- resolve cache (U2): key -> { roots, meta, tick }. Crude size cap: resolved
-- trees are small, but unbounded growth across a long session isn't free.
local cache = {}
local cache_count = 0
local function cache_put(key, entry)
  if cache_count >= 50 then
    cache = {}
    cache_count = 0
  end
  if not cache[key] then
    cache_count = cache_count + 1
  end
  cache[key] = entry
end

--- Drop all cached resolutions (test seam + future manual refresh).
function M.clear_cache()
  cache = {}
  cache_count = 0
end

--- Number of cached resolutions (test seam).
function M._cache_count()
  return cache_count
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
  -- ctx.pierce (user-initiated recurse): an explicit expand is the user
  -- ASKING for stub internals — the guard only protects automatic resolution
  if not ctx.pierce and is_typeshed(loc.uri) then
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

--- True when a parsed signature carries no annotations at all — the tell for
--- stub-typed packages (l24): the runtime .py pyright's source mapper prefers
--- is untyped, and the real signatures live in a handwritten .pyi.
---@param info { params: table[], return_type: TSNode? }
---@return boolean
local function unannotated(info)
  if info.return_type then
    return false
  end
  for _, p in ipairs(info.params) do
    if p.type_node then
      return false
    end
  end
  return true
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

--- Structural resolution came up empty for a node (alias, TypeVar,
--- unresolvable, unannotated param): queue it for hover enrichment. The
--- hovers all fire in PARALLEL at the end of the pipeline (U2) — they are
--- independent, and ~8 sequential round-trips were a third of uvicorn.run's
--- open time.
---@param ctx typescope.ResolveCtx
---@param node typescope.Node
---@param src_buf integer
---@param refs table[] annotation refs (position candidates, tried in order)
local function queue_enrichment(ctx, node, src_buf, refs)
  table.insert(ctx.enrich, { node = node, src_buf = src_buf, refs = refs })
end

--- Fire every queued enrichment hover concurrently, then apply the first
--- *informative* answer per node in ref order — a hover that merely echoes
--- the name back (a class behind the typeshed guard says "(class) Protocol")
--- decorates nothing, but an alias expansion or an inferred type does.
---@param ctx typescope.ResolveCtx
local function run_enrichment(ctx)
  local jobs = {}
  local total = 0
  for _, item in ipairs(ctx.enrich) do
    local cands = {}
    for i = 1, math.min(#item.refs, 3) do
      table.insert(cands, { ref = item.refs[i] })
      total = total + 1
    end
    table.insert(jobs, { node = item.node, src_buf = item.src_buf, cands = cands })
  end
  ctx.enrich = {}
  if total == 0 then
    return
  end

  async.await(function(resume)
    local remaining = total
    local resumed = false
    local function one_done()
      remaining = remaining - 1
      if remaining == 0 and not resumed then
        resumed = true
        resume()
      end
    end
    for _, job in ipairs(jobs) do
      for _, cand in ipairs(job.cands) do
        local params = lsp.position_params(job.src_buf, cand.ref.row, cand.ref.col)
        lsp.request_cb(ctx.client, "textDocument/hover", params, ctx.token, function(err, result)
          cand.result = not err and result or nil
          one_done()
        end)
      end
    end
  end)
  if async.stale(ctx.token) then
    return
  end

  for _, job in ipairs(jobs) do
    for _, cand in ipairs(job.cands) do
      local lines = lsp.hover_result_lines(cand.result)
      local evaluated = lines and ctx.impl.evaluated_from_hover(lines, cand.ref.name)
      if
        evaluated
        and evaluated ~= job.node.type.display
        and evaluated ~= cand.ref.name
        and evaluated ~= cand.ref.name:match("[%w_]+$")
        and evaluated ~= "Any"
      then
        job.node.evaluated = evaluated
        -- which annotation piece answered: for a multi-ref union the ≈ view
        -- belongs to ONE member (WSProtocolType, not the whole union) and
        -- the ledger detail names it so adjacency isn't mistaken for scope
        job.node.evaluated_owner = cand.ref.name:match("[%w_]+$") or cand.ref.name
        break
      end
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
          local next_ancestry = vim.tbl_extend("force", {}, base_ancestry, { [loc_key(brealloc)] = true })
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
        -- beyond depth: leave a lazy hook for expand (<CR>/l)
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
    elseif loc and not ancestry[loc_key(loc)] and (ctx.pierce or not is_typeshed(loc.uri)) then
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
    queue_enrichment(ctx, node, src_buf, refs)
  end
end

--- Full pipeline for the function under the cursor. Coroutine context only.
---@param client vim.lsp.Client
---@param bufnr integer source buffer
---@param win integer source window (cursor position)
---@param token typescope.CancelToken
---@param pos? { [1]: integer, [2]: integer } (1-based row, byte col) override —
--- the insert-mode surface resolves the call's callee, not the cursor
---@return typescope.Node[]? roots
---@return table|string|nil meta_or_err on success: { header?: string, docstring?: string }; on failure: error message
function M.function_scope(client, bufnr, win, token, pos)
  local ft = vim.bo[bufnr].filetype
  local impl = extract.get(ft)
  if not impl then
    return nil, ("no extractor for filetype %q"):format(ft)
  end
  local ctx = { client = client, token = token, impl = impl, enrich = {} }

  pos = pos or vim.api.nvim_win_get_cursor(win)
  local loc = lsp.definition(client, bufnr, pos[1] - 1, pos[2], token)
  if async.stale(token) then
    return nil, "stale"
  end
  if not loc then
    return nil, "no definition found for symbol under cursor"
  end

  local fbuf = lsp.load_buf(loc.uri)

  -- resolve cache (U2): warm reopen of the same symbol reuses the tree —
  -- folds, lazy expansions, and LLM values survive for free. Invalidated by
  -- edits to the definition buffer (changedtick) and by config depth.
  local cache_key = ("%s#%d#%s#%d"):format(loc.uri, loc.range.start.line, ft, config.get().depth)
  local cache_tick = vim.b[fbuf].changedtick
  local hit = cache[cache_key]
  if hit and hit.tick == cache_tick then
    return hit.roots, hit.meta
  end

  local frow, fcol = lsp.range_start(fbuf, loc.range)
  local info = impl.function_info(fbuf, frow, fcol)
  if not info then
    -- A class under the cursor is the most TypeScope-shaped thing there is:
    -- show the type's own structure directly (class_at_location handles the
    -- import hop and the typeshed guard, so `str` won't explode here).
    local cls, tbuf, realloc = class_at_location(ctx, loc, 0)
    if cls and (#cls.fields > 0 or #cls.methods > 0 or #(cls.bases or {}) > 0) then
      -- header declares the ancestry up top: (pydantic ← UserBase)
      local function header()
        local names = {}
        for _, base in ipairs(cls.bases or {}) do
          table.insert(names, base.name)
        end
        return "(" .. cls.category .. (#names > 0 and " ← " .. table.concat(names, ", ") or "") .. ")"
      end
      local root = model.new({
        name = cls.class_name,
        kind = "type",
        expanded = true,
        type = {
          raw = cls.class_name,
          display = header(),
          category = cls.category,
        },
      })
      populate_from_class(ctx, root, cls, tbuf, 1, { [loc_key(realloc)] = true })
      if async.stale(token) then
        return nil, "stale"
      end
      if #root.children > 0 then
        run_enrichment(ctx)
        if async.stale(token) then
          return nil, "stale"
        end
        -- category may have been corrected by the base walk (UserCreate case)
        root.type.display = header()
        require("typescope.examples").annotate({ root })
        -- no call-shape header for a class hover: the root row is the header
        local roots, meta = { root }, { docstring = cls.docstring }
        cache_put(cache_key, { roots = roots, meta = meta, tick = cache_tick })
        return roots, meta
      end
    end
  end

  -- Definition is a *runtime* question and may land on an alias assignment
  -- (stdlib getpass = unix_getpass, parses to nothing) or on untyped runtime
  -- code shadowing a handwritten stub (loguru's add — pyright's source mapper
  -- prefers the .py, so the parse sees zero annotations: l24). Declaration
  -- asks the static universe instead: the stub's annotated `def` — or its
  -- first @overload sibling, which the U4 scan below expands to the full
  -- set — parses through the exact same path.
  if not info or unannotated(info) then
    local decl = lsp.locate(client, bufnr, pos[1] - 1, pos[2], token, "textDocument/declaration")
    if async.stale(token) then
      return nil, "stale"
    end
    if decl and loc_key(decl) ~= loc_key(loc) then
      local dbuf = lsp.load_buf(decl.uri)
      local drow, dcol = lsp.range_start(dbuf, decl.range)
      local dinfo = impl.function_info(dbuf, drow, dcol)
      -- an unannotated definition parse is only abandoned for a BETTER one:
      -- declaration answering with another bare signature proves nothing
      if dinfo and (not info or not unannotated(dinfo)) then
        -- stub bodies are `...` — the runtime docstring rides along
        dinfo.docstring = dinfo.docstring or (info and info.docstring)
        fbuf, frow, fcol, info = dbuf, drow, dcol, dinfo
      end
    end
  end
  if not info then
    return nil, "symbol does not resolve to a function definition or class"
  end

  -- overloads (U4): sibling @overload defs become stacked group roots, each
  -- with shallow param/return children — annotations straight from the def
  -- site, no definition chases; structure lazy-loads on expand. Which group
  -- is ACTIVE is a per-call decision the surfaces make from signatureHelp,
  -- so the cache stores the whole set plus per-overload headers.
  local overload_locs = impl.overloads and impl.overloads(fbuf, frow, fcol)
  if overload_locs then
    local uri = vim.uri_from_bufnr(fbuf)
    -- seeded from info: after a declaration hop the @overload defs have `...`
    -- bodies and the docstring lives on the runtime def that info carried over
    local groups, headers, docstring = {}, {}, info.docstring
    local function shallow_child(name, kind, ann, default, mode)
      local child = model.new({
        name = name,
        kind = kind,
        type = ann and type_info(ann.display, ann.refs) or { raw = "Any", display = "Any", category = "builtin" },
        default = default,
        pass_mode = mode,
      })
      if ann and #ann.refs > 0 then
        child.state.loaded = false
        child.source = { uri = uri, range = { start = { line = ann.refs[1].row, character = 0 } } }
        child._lazy = { uri = uri, refs = ann.refs, ancestry = {}, impl = impl }
      end
      return child
    end
    for _, o in ipairs(overload_locs) do
      local oinfo = impl.function_info(fbuf, o.row, o.col)
      if oinfo then
        docstring = docstring or oinfo.docstring
        local ret = oinfo.return_type and impl.annotation(fbuf, oinfo.return_type)
        local group = model.new({
          id = "overload" .. (#groups + 1),
          name = oinfo.name,
          kind = "overload",
          type = { raw = "", display = "(" .. table.concat(oinfo.shape or {}, ", ") .. ")", category = "builtin" },
        })
        for _, p in ipairs(oinfo.params) do
          local ann = p.type_node and impl.annotation(fbuf, p.type_node)
          model.add_child(group, shallow_child(p.name, "param", ann, p.default, p.mode))
        end
        if ret then
          model.add_child(group, shallow_child("returns", "return", ret))
        end
        table.insert(groups, group)
        table.insert(
          headers,
          oinfo.name .. "(" .. table.concat(oinfo.shape or {}, ", ") .. ")" .. (ret and (" -> " .. ret.display) or "")
        )
      end
    end
    if #groups >= 2 then
      for i, g in ipairs(groups) do
        g.badge = ("[%d/%d]"):format(i, #groups)
      end
      groups[1].state.expanded = true -- surfaces re-aim this at the active one
      require("typescope.examples").annotate(groups)
      local meta = { header = headers[1], headers = headers, overloads = #groups, docstring = docstring }
      cache_put(cache_key, { roots = groups, meta = meta, tick = cache_tick })
      return groups, meta
    end
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
      pass_mode = p.mode,
    })
    if ann and #ann.refs > 0 then
      attach_type(ctx, node, fbuf, ann.refs, 1, {})
      if async.stale(token) then
        return nil, "stale"
      end
    elseif not p.type_node and p.name_row then
      -- unannotated param: pyright still infers a type — hover the name
      -- (joins the same parallel enrichment fan-out as failed leaves)
      queue_enrichment(ctx, node, fbuf, { { name = p.name, row = p.name_row, col = p.name_col } })
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
  run_enrichment(ctx)
  if async.stale(token) then
    return nil, "stale"
  end
  require("typescope.examples").annotate(roots)

  local ret = info.return_type and impl.annotation(fbuf, info.return_type).display
  local meta = {
    header = info.name .. "(" .. table.concat(info.shape or {}, ", ") .. ")" .. (ret and (" -> " .. ret) or ""),
    docstring = info.docstring,
  }
  cache_put(cache_key, { roots = roots, meta = meta, tick = cache_tick })
  return roots, meta
end

--- Lazily resolve a beyond-depth node (expanding an unloaded node).
--- Runs its own coroutine; cb fires on success.
---@param client vim.lsp.Client
--- Light evaluation for the typing surface: fetch pyright's ≈ view of a
--- _lazy param (alias / typeshed-blocked chase) WITHOUT resolving its
--- structure — the hook stays attached, so explicit expansion in the reading
--- float still chases. One hover per ref, first informative answer wins;
--- same validity filter as run_enrichment. cb(true) when something landed.
---@param client vim.lsp.Client
---@param node typescope.Node
---@param token typescope.CancelToken
---@param cb fun(filled: boolean)
function M.evaluate(client, node, token, cb)
  local lazy = node._lazy
  if not lazy or node.evaluated or #lazy.refs == 0 then
    return cb(false)
  end
  async.run(function()
    local bufnr = lsp.load_buf(lazy.uri)
    for i = 1, math.min(#lazy.refs, 3) do
      local ref = lazy.refs[i]
      local err, result = async.await(function(resume)
        lsp.request_cb(client, "textDocument/hover", lsp.position_params(bufnr, ref.row, ref.col), token, resume)
      end)
      if async.stale(token) then
        return cb(false)
      end
      local lines = not err and lsp.hover_result_lines(result) or nil
      local evaluated = lines and lazy.impl.evaluated_from_hover(lines, ref.name)
      if
        evaluated
        and evaluated ~= node.type.display
        and evaluated ~= ref.name
        and evaluated ~= ref.name:match("[%w_]+$")
        and evaluated ~= "Any"
      then
        node.evaluated = evaluated
        node.evaluated_owner = ref.name:match("[%w_]+$") or ref.name
        return cb(true)
      end
    end
    cb(false)
  end)
end

---@param node typescope.Node
---@param token typescope.CancelToken
---@param cb fun()
function M.recurse(client, node, token, cb)
  local lazy = node._lazy
  if not lazy or node.state.loading then
    return
  end
  node.state.loading = true
  -- clear the hook BEFORE resolving: attach_type's evaluated-hover fallback
  -- (for chases the typeshed guard blocks — every param of a typeshed def)
  -- is gated on "no lazy hook pending", so a still-attached hook silently
  -- swallowed the ≈ decoration and expanding did nothing at all
  node._lazy = nil
  async.run(function()
    -- pierce = true: see class_at_location — explicit expansion may enter
    -- typeshed (open()'s returns showing TextIOWrapper's structure is the
    -- whole point of the keypress)
    local ctx = { client = client, token = token, impl = lazy.impl, enrich = {}, pierce = true }
    local bufnr = lsp.load_buf(lazy.uri)
    attach_type(ctx, node, bufnr, lazy.refs, 1, lazy.ancestry or {})
    run_enrichment(ctx)
    node.state.loading = false
    if async.stale(token) then
      -- Cancelled mid-chase — the CursorMoved dismissal that closes the float
      -- is the ordinary way to get here. Put the node back exactly as we found
      -- it. The hook was cleared up front (see above) because attach_type's
      -- enrichment fallback is gated on its absence, but leaving it cleared
      -- STRANDS the node: `loaded` is still false and `source` is still set,
      -- so it keeps its expander marker, while recurse_into finds no hook to
      -- fire and <CR> falls through to a plain toggle that reveals nothing.
      -- The resolve cache then hands that same dead node back on every reopen
      -- of the symbol.
      --
      -- Children are dropped rather than kept. A partial chase plus a restored
      -- hook appends a SECOND set of children on the retry; a cancelled
      -- recurse being a no-op is the only honest state, and the float is
      -- already gone, so nobody is looking at what landed. A node holding a
      -- hook never has children of its own to lose (attach_type only sets
      -- _lazy where it declined to recurse), so this restores the exact
      -- pre-call state rather than merely a plausible one.
      node.children = {}
      node._lazy = lazy
      return
    end
    if #node.children > 0 then
      node.state.loaded = true
      node.state.expanded = true
    elseif node.evaluated then
      -- evaluation-only outcome: keep the node expandable (loaded stays
      -- false, source stays set) so the ≈ view folds like any branch —
      -- h collapses THIS node, not its parent. Re-expanding is a plain
      -- toggle: _lazy is gone, so no re-resolve.
      node.evaluated_on_expand = true
      node.state.expanded = true
    else
      node.state.loaded = true -- honest leaf: nothing behind the marker
      node.state.expanded = false
    end
    require("typescope.examples").annotate({ node })
    cb()
  end)
end

return M
