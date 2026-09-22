-- resolve_oracle.lua against the real binary: the Scope → Node adapter, the
-- three-way decline, the cache, lazy expansion by re-asking deeper, overload
-- groups, the constructor on a call, and a float opened through the plugin.
--
-- Needs a built binary (scripts/build-oracle.sh); skips itself otherwise.
local bin = vim.env.TYPESCOPE_ORACLE or (vim.fn.getcwd() .. "/oracle/target/debug/typescope-oracle")
if vim.fn.executable(bin) ~= 1 then
  print("SKIP test_resolve_oracle: no oracle binary at " .. bin .. " (scripts/build-oracle.sh)")
  print("ALL PASS")
  return
end

local failures = 0
local function check(cond, msg)
  if cond then
    print("ok   " .. msg)
  else
    failures = failures + 1
    print("FAIL " .. msg)
  end
end

require("typescope").setup({ resolver = "oracle", oracle = { path = bin }, depth = 2 })
local resolve = require("typescope.resolve_oracle")
local async = require("typescope.async")

local fixture = vim.fn.getcwd() .. "/tests/fixtures/shapes.py"
vim.cmd.edit(fixture)
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = "python"
local win = vim.api.nvim_get_current_win()
vim.wait(20000, function()
  local c = require("typescope.lsp").oracle_for(bufnr)
  return c ~= nil and c.initialized
end, 50)

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local function line_of(prefix)
  for i, l in ipairs(lines) do
    if l:sub(1, #prefix) == prefix then
      return i
    end
  end
  error("no line starting with " .. prefix)
end

--- Run function_scope at a 1-based (row, byte col) and wait for it.
local function scope_at(row, col)
  local roots, meta, why, done
  async.run(function()
    roots, meta, why = resolve.function_scope(nil, bufnr, win, async.token(), { row, col })
    done = true
  end)
  vim.wait(20000, function()
    return done
  end, 10)
  return roots, meta, why
end

local function names(nodes)
  local out = {}
  for _, n in ipairs(nodes or {}) do
    out[#out + 1] = n.name
  end
  return table.concat(out, ",")
end

-- a function: params + returns, header, docstring, expansion policy
do
  local roots, meta = scope_at(line_of("def takes_config"), 4)
  check(roots ~= nil, "takes_config resolves")
  check(names(roots) == "config,timeout,returns", "roots are config,timeout,returns (got " .. names(roots) .. ")")
  check(meta.header == "takes_config(config, timeout=…) -> User", "header (got " .. tostring(meta.header) .. ")")
  check(type(meta.docstring) == "string", "docstring carried")
  check(roots[1].state.expanded and not roots[2].state.expanded, "param with structure starts open, leaf closed")
  check(not roots[3].state.expanded and #roots[3].children > 0, "returns starts collapsed even with structure")
  check(names(roots[1].children) == "host,port,debug", "config's fields (got " .. names(roots[1].children) .. ")")
  check(roots[1].children[2].default == "8000", "port default")
  check(roots[1].type.category == "dataclass", "category dataclass")
  check(roots[2].default == "30.0", "timeout default")
  check(roots[3].kind == "return" and roots[3].type.category == "pydantic", "returns User is pydantic")
  check(roots[1].id == "config" and roots[1].children[1].id == "config.host", "ids are dotted paths")
end

-- cache: same position, same tick → the same tree
do
  local before = resolve._cache_count()
  local a = scope_at(line_of("def takes_config"), 4)
  local b = scope_at(line_of("def takes_config"), 4)
  check(a == b and resolve._cache_count() == before, "second ask is a cache hit")
  resolve.clear_cache()
  check(resolve._cache_count() == 0, "clear_cache empties it")
end

-- inferred rides on evaluated with type Any (the renderer's ≈)
do
  local roots = scope_at(line_of("class Unannotated:"), 6)
  local strong = roots[1].children[1]
  check(
    strong.name == "strong" and strong.type.display == "Any" and strong.evaluated == "str",
    "inferred member → Any ≈ str"
  )
end

-- class scope: root open, header row
do
  local roots, meta = scope_at(line_of("class DerivedConfig"), 6)
  check(roots[1].kind == "type" and roots[1].state.expanded, "class root is an expanded type node")
  check(roots[1].type.display == "(class ← BaseConfig)", "class header (got " .. roots[1].type.display .. ")")
  check(meta.header == nil, "no call-shape header for a class")
  check(roots[1].children[2].origin == "BaseConfig", "inherited env carries ↑BaseConfig")
end

-- the empty decline
do
  local roots, reason, why = scope_at(line_of("    def oddly_named"), 8)
  -- oddly_named(numpy_test) -> None: receiver only, declared None return → returns row only
  check(roots ~= nil and names(roots) == "returns", "receiver-only def with -> None keeps its returns row")
  local q = vim.fn.getcwd() .. "/tests/fixtures/oracle/oracle.py"
  vim.cmd.edit(q)
  local qb = vim.api.nvim_get_current_buf()
  vim.bo[qb].filetype = "python"
  vim.wait(20000, function()
    local c = require("typescope.lsp").oracle_for(qb)
    return c ~= nil and c.initialized
  end, 50)
  local qlines = vim.api.nvim_buf_get_lines(qb, 0, -1, false)
  local nrow
  for i, l in ipairs(qlines) do
    if l == "    def n(self):" then
      nrow = i
    end
  end
  local r2, reason2, why2
  local done
  async.run(function()
    r2, reason2, why2 = resolve.function_scope(nil, qb, vim.api.nvim_get_current_win(), async.token(), { nrow, 8 })
    done = true
  end)
  vim.wait(20000, function()
    return done
  end, 10)
  check(
    r2 == nil and why2 == "empty" and reason2 == "n has no parameters or return annotation",
    "empty decline with the resolver's reason (" .. tostring(reason2) .. ")"
  )
  -- absent: a string literal
  done = false
  local r3, _, why3
  async.run(function()
    r3, _, why3 = resolve.function_scope(nil, qb, vim.api.nvim_get_current_win(), async.token(), { 1, 0 })
    done = true
  end)
  vim.wait(20000, function()
    return done
  end, 10)
  check(r3 == nil and why3 == "absent", "docstring position → absent")

  -- overloads: stacked groups, first expanded, headers
  local prow
  for i, l in ipairs(qlines) do
    if l:match("^def pick%(key: int%)") then
      prow = i
    end
  end
  done = false
  local ro, mo
  async.run(function()
    ro, mo = resolve.function_scope(nil, qb, vim.api.nvim_get_current_win(), async.token(), { prow, 4 })
    done = true
  end)
  vim.wait(20000, function()
    return done
  end, 10)
  check(ro and #ro == 2 and ro[1].id == "overload1" and ro[2].id == "overload2", "two overload groups with stable ids")
  check(ro and ro[1].state.expanded and not ro[2].state.expanded, "first group expanded")
  check(mo and mo.overloads == 2 and mo.headers[2] == "pick(key, default=…) -> str", "meta.headers/overloads")
  check(ro and ro[2].children[2].id == "overload2.default", "group children re-rooted under the group id")

  -- constructor on a call: `self.cfg: ServerConfig = ServerConfig("h")`, cursor on the RHS name
  local crow, ccol
  for i, l in ipairs(qlines) do
    local s = l:find('= ServerConfig("h")', 1, true)
    if s then
      crow, ccol = i, s + 2
    end
  end
  done = false
  local rc, mc
  async.run(function()
    rc, mc = resolve.function_scope(nil, qb, vim.api.nvim_get_current_win(), async.token(), { crow, ccol })
    done = true
  end)
  vim.wait(20000, function()
    return done
  end, 10)
  check(
    mc and mc.header == "ServerConfig(host, port=…) -> ServerConfig",
    "class under a call → constructor header (got " .. tostring(mc and mc.header) .. ")"
  )
  check(rc and names(rc) == "host,port,returns", "constructor roots (got " .. names(rc) .. ")")

  -- lazy expansion: depth 1 leaves `item` expandable; recurse re-asks deeper
  require("typescope.config").setup({ resolver = "oracle", oracle = { path = bin }, depth = 1 })
  resolve.clear_cache()
  local urow
  for i, l in ipairs(qlines) do
    if l:match("^def use%(") then
      urow = i
    end
  end
  done = false
  local ru
  async.run(function()
    ru = resolve.function_scope(nil, qb, vim.api.nvim_get_current_win(), async.token(), { urow, 4 })
    done = true
  end)
  vim.wait(20000, function()
    return done
  end, 10)
  local item = ru and ru[1].children[1]
  check(
    item and item.name == "item" and not item.state.loaded and item._lazy ~= nil,
    "depth 1: Box.item is a lazy node"
  )
  local grafted = false
  resolve.recurse(nil, item, async.token(), function()
    grafted = true
  end)
  vim.wait(20000, function()
    return grafted
  end, 10)
  check(grafted and item.state.loaded and item.state.expanded, "recurse loaded and expanded it")
  check(names(item.children) == "host,port", "grafted ServerConfig's fields (got " .. names(item.children) .. ")")
  check(item.children[1].id == "b.item.host", "grafted ids re-rooted under the node")
  require("typescope.config").setup({ resolver = "oracle", oracle = { path = bin }, depth = 2 })
end

-- through the plugin: open the float on takes_config and read it
do
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_win_set_cursor(0, { line_of("def takes_config"), 4 })
  require("typescope").open({ focus = false })
  local float
  vim.wait(20000, function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        float = w
      end
    end
    return float ~= nil
  end, 20)
  check(float ~= nil, "float opened through typescope.open()")
  if float then
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false), "\n")
    check(text:find("takes_config(config, timeout=…) -> User", 1, true) ~= nil, "float shows the header")
    check(text:find("host", 1, true) and text:find("8000", 1, true), "float shows config's fields and a default")
    check(text:find("returns", 1, true) ~= nil, "float shows returns")
  end
  require("typescope").close()
end

-- the insert-mode typing surface on the oracle path (bead lfy): cursor
-- inside `ServerConfig("h")`'s parens, drive the insert entry point the way
-- e2e_phase3 does (insert mode itself is unreachable headless)
do
  require("typescope").setup({ resolver = "oracle", oracle = { path = bin }, insert_mode = { enabled = true } })
  local q = vim.fn.getcwd() .. "/tests/fixtures/oracle/oracle.py"
  vim.cmd.edit(q)
  local qb = vim.api.nvim_get_current_buf()
  vim.bo[qb].filetype = "python"
  vim.wait(20000, function()
    local c = require("typescope.lsp").oracle_for(qb)
    return c ~= nil and c.initialized
  end, 50)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(qb, 0, -1, false)) do
    local s = l:find('= ServerConfig("h")', 1, true)
    if s then
      vim.api.nvim_win_set_cursor(0, { i, s + 14 }) -- inside the parens
    end
  end
  require("typescope.insert")._update()
  local iw
  vim.wait(20000, function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local c = vim.api.nvim_win_get_config(w)
      if c.relative ~= "" and vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "typescope" then
        iw = w
      end
    end
    return iw ~= nil
  end, 20)
  check(iw ~= nil, "insert surface opened on the oracle path")
  if iw then
    local itext = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(iw), 0, -1, false), "\n")
    check(
      itext:find("host", 1, true) ~= nil and itext:find("port", 1, true) ~= nil,
      "typing surface lists the constructor's params"
    )
  end
  require("typescope.insert").close()
end

for _, c in ipairs(vim.lsp.get_clients({ name = "typescope-oracle" })) do
  if vim.fn.has("nvim-0.11") == 1 then
    c:stop(true)
  else
    vim.lsp.stop_client(c.id, true)
  end
end
vim.wait(1000)

if failures == 0 then
  print("ALL PASS")
else
  print(("FAILURES: %d"):format(failures))
end
