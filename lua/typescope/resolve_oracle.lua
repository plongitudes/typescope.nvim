-- The resolver, on the oracle (design/oracle.md §5): the same three entry
-- points `resolve.lua` exposes — function_scope, recurse, clear_cache — with
-- the pipeline replaced by one `typescope/structure` request and an adapter
-- from the wire Scope to the Node trees the float already draws.
--
-- This file lives beside `resolve.lua` until the parity gate (bead 9) has
-- diffed the two; bead 10 deletes the old one and renames this.
--
-- Behaviors carried over from resolve.lua, by name, so a reader can check
-- each was kept rather than lost with the code that implemented it:
--   the three-way decline ("stale" / "absent" / "empty"), so K can stay
--     silent on a miss and speak on a deliberate decline;
--   the resolve cache keyed on position + depth and invalidated by the
--     buffer's changedtick, so a reopen paints warm;
--   auto-expand policy: params with structure start open, deeper closed,
--     a class root open, a declaration open when it has children;
--   overload sets as stacked groups with [i/n] badges, the first expanded
--     until the surface re-aims it at the active one;
--   a cancelled recurse is a no-op: the hook goes back on, nothing
--     half-grafted stays (the resolve cache would hand a dead node back);
--   an evaluation-only expand keeps the ≈ view foldable (evaluated_on_expand);
--   "prefer a row over a decline": a declaration always draws.
-- Dropped, deliberately, because the oracle answers them directly: the
-- definition/declaration chase, the alias hop, the typeshed guard and the
-- pierce-on-expand exception, the hover-prose enrichment fan-out, the
-- receiver-by-position and stub-hop rules (all in the oracle's policy).

local async = require("typescope.async")
local model = require("typescope.model")
local config = require("typescope.config")

local M = {}

-- resolve cache: key -> { roots, meta, tick }. Same crude cap as before.
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

function M.clear_cache()
  cache = {}
  cache_count = 0
end

function M._cache_count()
  return cache_count
end

--- Wire Node → model spec. `inferred` rides on `evaluated` with a type of
--- "Any", which is how the renderer already draws ≈ (bead 7 moves it onto
--- `inferred` proper). `expandable` becomes the lazy hook recurse() fires.
---@param n table wire node
---@param lazy { bufnr: integer, pos: table, members: string, call: boolean }
---@return table spec for model.new
local function to_spec(n, lazy)
  local display = n.type and n.type.display or "?"
  local category = n.type and n.type.category or "unresolved"
  local spec = {
    name = n.name,
    kind = n.kind,
    type = { raw = display, display = n.inferred and "Any" or display, category = category },
    default = n.default,
    badge = n.badge,
    origin = n.origin,
    pass_mode = n.pass_mode,
    inferred = n.inferred or false,
    evaluated = n.inferred and display or nil,
    source = n.location
        and { uri = n.location.uri, range = { start = { line = n.location.line, character = n.location.character } } }
      or nil,
    children = {},
  }
  for _, c in ipairs(n.children or {}) do
    table.insert(spec.children, to_spec(c, lazy))
  end
  if n.expandable then
    spec.loaded = false
  end
  return spec
end

--- model.new drops unknown spec keys, so the lazy hook is attached after.
--- `id` overrides the root's id (overload groups need distinct ones).
local function build(n, lazy, id)
  local spec = to_spec(n, lazy)
  spec.id = id
  local node = model.new(spec)
  local function attach(wire, built)
    if wire.expandable then
      built.state.loaded = false
      built._lazy = lazy
    end
    for i, c in ipairs(wire.children or {}) do
      if built.children[i] then
        attach(c, built.children[i])
      end
    end
  end
  attach(n, node)
  return node
end

--- Is the cursor on the callee of a call? Decision 5: a class under a call
--- draws its constructor. Call-site syntax, so treesitter over the buffer.
local function on_callee(bufnr, row, col)
  local impl = require("typescope.extract").get(vim.bo[bufnr].filetype)
  return impl and impl.on_callee and impl.on_callee(bufnr, row, col) or false
end

--- Full pipeline for the symbol under the cursor. Coroutine context only.
---@param client vim.lsp.Client? kept for signature parity; the oracle client is found per buffer
---@param bufnr integer
---@param win integer
---@param token typescope.CancelToken
---@param pos? { [1]: integer, [2]: integer } (1-based row, byte col) override
---@return typescope.Node[]? roots
---@return table|string|nil meta_or_err
---@return string? why "stale" | "absent" | "empty"
function M.function_scope(client, bufnr, win, token, pos)
  local _ = client
  local oracle = require("typescope.oracle")
  if not oracle.client_for(bufnr) then
    return nil, "typescope: oracle not attached to this buffer (see :checkhealth typescope)", "absent"
  end
  pos = pos or vim.api.nvim_win_get_cursor(win)
  local row0, col = pos[1] - 1, pos[2]
  local lsp = require("typescope.lsp")
  local line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1] or ""
  local character = lsp.to_utf16(line, col)
  local cfg = config.get()
  local call = on_callee(bufnr, row0, col)

  local cache_key = ("%s#%d#%d#%s#%d"):format(vim.uri_from_bufnr(bufnr), row0, character, tostring(call), cfg.depth)
  local cache_tick = vim.b[bufnr].changedtick
  local hit = cache[cache_key]
  if hit and hit.tick == cache_tick then
    return hit.roots, hit.meta
  end

  local err, scope = async.await(function(resume)
    oracle.request(
      bufnr,
      { position = { line = row0, character = character }, depth = cfg.depth, call = call },
      token,
      resume
    )
  end)
  if async.stale(token) then
    return nil, "stale", "stale"
  end
  if err then
    return nil, tostring(err), "absent"
  end
  if not scope then
    return nil, "no definition found for symbol under cursor", "absent"
  end
  if scope.scope == "empty" then
    return nil, scope.reason or "nothing to draw", "empty"
  end

  local lazy = { bufnr = bufnr, pos = { row0, character }, call = call }
  local roots = {}
  for i, n in ipairs(scope.roots) do
    -- overload groups get the ids the surfaces already key on
    table.insert(roots, build(n, lazy, scope.overloads and ("overload" .. i) or nil))
  end

  local meta = { header = scope.header, docstring = scope.docstring }
  if scope.overloads then
    -- stacked groups; the surface re-aims the expansion at the active one
    for i, g in ipairs(roots) do
      g.state.expanded = i == 1
    end
    meta.headers = scope.headers
    meta.overloads = scope.overloads
  elseif scope.scope == "class" then
    roots[1].state.expanded = true
  elseif scope.scope == "declaration" then
    roots[1].state.expanded = #roots[1].children > 0
  else
    -- function / constructor: params with resolved structure start open
    for _, r in ipairs(roots) do
      r.state.expanded = #r.children > 0
    end
  end

  require("typescope.examples").annotate(roots)
  cache_put(cache_key, { roots = roots, meta = meta, tick = cache_tick })
  return roots, meta
end

--- Depth of a node in the tree by its dotted id: roots are 0.
local function id_depth(id)
  local _, dots = id:gsub("%.", "")
  return dots
end

--- Find the node with `id` in a forest (ids are dotted paths).
local function find_by_id(roots, id)
  return model.find(roots, id)
end

--- Lazily resolve a beyond-depth node: re-ask the ORIGINAL position with a
--- depth that reaches this node's children (design/oracle.md §4 — asking at
--- the member's own declaration would answer with the unspecialized type),
--- then graft the subtree found at the same id path.
---@param client vim.lsp.Client?
---@param node typescope.Node
---@param token typescope.CancelToken
---@param cb fun()
function M.recurse(client, node, token, cb)
  local _ = client
  local lazy = node._lazy
  if not lazy or node.state.loading then
    return
  end
  node.state.loading = true
  node._lazy = nil
  local oracle = require("typescope.oracle")
  async.run(function()
    local depth = id_depth(node.id) + 2
    local err, scope = async.await(function(resume)
      oracle.request(
        lazy.bufnr,
        { position = { line = lazy.pos[1], character = lazy.pos[2] }, depth = depth, call = lazy.call },
        token,
        resume
      )
    end)
    node.state.loading = false
    if async.stale(token) then
      -- cancelled: put the hook back, graft nothing (resolve.lua's rule)
      node._lazy = lazy
      return
    end
    local fresh = {}
    if not err and scope and scope.roots then
      for i, n in ipairs(scope.roots) do
        table.insert(fresh, build(n, lazy, scope.overloads and ("overload" .. i) or nil))
      end
    end
    local twin = find_by_id(fresh, node.id)
    if twin and #twin.children > 0 then
      node.children = {}
      for _, c in ipairs(twin.children) do
        model.add_child(node, c)
      end
      node.state.loaded = true
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
