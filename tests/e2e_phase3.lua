-- End-to-end test of the phase-3 LSP pipeline against the in-process mock
-- server. Run headless:
--   nvim --headless --clean \
--     --cmd "set rtp+=. rtp+=~/.local/share/nvim/site" \
--     -c "luafile tests/e2e_phase3.lua" -c "qa!"

local root = vim.fn.getcwd()
local fixture_dir = root .. "/tests/fixtures"

local failures = 0
local function check(desc, cond)
  print((cond and "PASS " or "FAIL ") .. desc)
  if not cond then
    failures = failures + 1
  end
end

local function float_lines()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local c = vim.api.nvim_win_get_config(w)
    if c.relative ~= "" and vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "typescope" then
      return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), w
    end
  end
end

-- open the fixture and attach the mock server
vim.cmd.edit(fixture_dir .. "/sample.py")
local bufnr = vim.api.nvim_get_current_buf()
local client_id = vim.lsp.start({
  name = "typescope-mock",
  cmd = require("tests.mock_server").cmd(fixture_dir),
  root_dir = fixture_dir,
})
vim.wait(1000, function()
  return #vim.lsp.get_clients({ bufnr = bufnr }) > 0
end)
check("mock LSP attached", #vim.lsp.get_clients({ bufnr = bufnr }) > 0)

-- cursor on the create_server *call*
local call_line
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if l:find("handle = create_server") then
    call_line = i
  end
end
vim.api.nvim_win_set_cursor(0, { call_line, 12 })

require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)

local lines = float_lines()
check("float opened", lines ~= nil)
if lines then
  local all = table.concat(lines, "\n")
  check("param config expanded with fields", all:find("host") and all:find("port") and all:find("debug"))
  check("depth-2: retry's RetryPolicy category resolved", all:find("retry") ~= nil)
  check("union annotation intact", all:find("int | None", 1, true) ~= nil)
  check("param timeout with default", all:find("timeout") and all:find("30%.0"))
  check("returns Response present, collapsed", all:find("returns") and not all:find("status"))
  check("heuristic examples rendered (host -> localhost)", all:find("localhost") ~= nil)
  check("inherited field with origin tag", all:find("env") ~= nil and all:find("↑BaseConfig", 1, true) ~= nil)
  local _, override_count = all:gsub("verbose", "")
  local verbose_badged = false
  for _, l in ipairs(lines) do
    if l:find("verbose") and l:find("↑", 1, true) then
      verbose_badged = true
    end
  end
  check("child override wins (verbose appears once, unbadged)", override_count == 1 and not verbose_badged)

  -- expand retry (depth 2 resolved its fields inline)
  local _, w = float_lines()
  vim.api.nvim_set_current_win(w)
  for i, l in ipairs(lines) do
    if l:find("retry") then
      vim.api.nvim_win_set_cursor(w, { i, 0 })
      break
    end
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  local all2 = table.concat(float_lines(), "\n")
  check("retry expands to max_attempts/backoff", all2:find("max_attempts") and all2:find("backoff"))

  -- expand returns: cross-file resolution into server_types.py
  for i, l in ipairs(float_lines()) do
    if l:find("returns") then
      vim.api.nvim_win_set_cursor(w, { i, 0 })
      break
    end
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  vim.wait(500, function()
    return table.concat(float_lines() or {}, "\n"):find("status") ~= nil
  end)
  local all3 = table.concat(float_lines(), "\n")
  check("returns expands to Response fields (cross-file)", all3:find("status") and all3:find("body"))
end

require("typescope").close()
check("closed cleanly", float_lines() == nil)

-- L must RESOLVE lazy nodes, not just flip `expanded`: `returns` is
-- cross-file lazy, and before this it came out marked open with nothing
-- underneath while <CR> on the same node resolved it fine.
-- the reopen must start cold: the resolve cache still holds the tree the
-- <CR> above already expanded, which would make this test vacuous
require("typescope.resolve").clear_cache()
vim.api.nvim_win_set_cursor(0, { call_line, 12 })
require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
do
  local before, lw = float_lines()
  check("reopened collapsed (status not yet resolved)", not table.concat(before, "\n"):find("status"))
  vim.api.nvim_set_current_win(lw)
  vim.api.nvim_feedkeys("L", "x", false)
  vim.wait(2000, function()
    return table.concat(float_lines() or {}, "\n"):find("status") ~= nil
  end)
  check("L resolves lazy nodes (returns expands to Response fields)", table.concat(float_lines(), "\n"):find("status") ~= nil)
end
require("typescope").close()

-- TypedDict path: badges from total=False
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if l:find("result = update_user") then
    vim.api.nvim_win_set_cursor(0, { i, 12 })
  end
end
require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
local lines4 = float_lines()
check("typeddict float opened", lines4 ~= nil)
if lines4 then
  local all4 = table.concat(lines4, "\n")
  check("typeddict fields with NotRequired badges", all4:find("email") and all4:find("NotRequired"))
  check("returns None leaf", all4:find("returns%s+None") ~= nil)
end
require("typescope").close()

-- declaration fallback: `ask` resolves (definition) to a module alias
-- assignment, then (declaration) to the annotated def — the getpass case
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if l:find("secret = ask") then
    vim.api.nvim_win_set_cursor(0, { i, 10 })
  end
end
require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
local lines5 = float_lines()
check("alias float opened via declaration fallback", lines5 ~= nil)
if lines5 then
  local all5 = table.concat(lines5, "\n")
  check("stub params rendered", all5:find("prompt") and all5:find("echo"))
  check("stub annotations rendered", all5:find("str") and all5:find("bool"))
  check("stub return type rendered", all5:find("returns") ~= nil)
end
require("typescope").close()

-- stub-typed package (l24): `attach` resolves (definition) to the untyped
-- runtime def in sinks.py; the fully unannotated parse triggers the
-- declaration hop into sinks_stub.py, where the U4 scan finds the @overload
-- set — the loguru case (log.add showed one def with sink: Any)
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if l:find("attached = attach") then
    vim.api.nvim_win_set_cursor(0, { i, 12 })
  end
end
require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
local lines_l24 = float_lines()
check("stub-typed package float opened via declaration hop", lines_l24 ~= nil)
if lines_l24 then
  local all_l24 = table.concat(lines_l24, "\n")
  check("stub overload set surfaced", all_l24:find("%[1/2%]") ~= nil and all_l24:find("%[2/2%]") ~= nil)
  -- client-side matching (h8h): the mock reports activeSignature=0 here
  -- (no commas before the cursor), so the string literal "app.log" picks
  -- the sink: str overload over sink: TextIO
  check("client pick expands the str overload [2/2]", lines_l24[1]:find("%[2/2%]") ~= nil)
  check("stub annotations replace Any", all_l24:find("sink") ~= nil and not all_l24:find("Any"))
  check("runtime docstring rides the hop", all_l24:find("Register a sink") ~= nil)

  -- d on an overload group's param (loguru's log.add case, 082): the group
  -- root is the callable, not a param, so the jump must resolve one level
  -- down — and land on sink's DEFINITION, not its prose mention in the
  -- first paragraph ("Register a sink for…")
  local ov_win = (function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        return w
      end
    end
  end)()
  vim.api.nvim_set_current_win(ov_win)
  local ov_buf = vim.api.nvim_win_get_buf(ov_win)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(ov_buf, 0, -1, false)) do
    if l:find("· sink ", 1, true) then
      vim.api.nvim_win_set_cursor(ov_win, { i, 0 })
      break
    end
  end
  vim.api.nvim_feedkeys("d", "x", false)
  local ov_l = vim.api.nvim_win_get_cursor(ov_win)[1]
  local ov_text = vim.api.nvim_buf_get_lines(ov_buf, ov_l - 1, ov_l, false)[1] or ""
  check("d on overload param lands on its docstring definition", ov_text:find("sink : file-like", 1, true) ~= nil)
  vim.api.nvim_feedkeys("d", "x", false)
end
require("typescope").close()

-- client-side matching (h8h) against scalar-only overloads: fetch("x") gets
-- activeSignature=0 from the mock (no commas), and key: int can never take a
-- string — the str overload wins
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if l:find("fetch2 = fetch") then
    vim.api.nvim_win_set_cursor(0, { i, 10 })
  end
end
require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
local lines_h8h = float_lines()
check("client-match float opened", lines_h8h ~= nil)
if lines_h8h then
  check("string literal disqualifies key: int, picks [2/2]", lines_h8h[1]:find("%[2/2%]") ~= nil)
end
require("typescope").close()

-- unified float (U1): single window with header + tree + docstring sections
local function all_floats()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      table.insert(out, w)
    end
  end
  return out
end

for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if l:find("handle = create_server") then
    vim.api.nvim_win_set_cursor(0, { i, 12 })
  end
end
require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
check("exactly one float (anchor retired)", #all_floats() == 1)
local ulines, ts_win = float_lines()
if ulines then
  local all_u = table.concat(ulines, "\n")
  check(
    "header: one-line call shape, elided to width, return kept",
    ulines[1]:find("create_server(config", 1, true) ~= nil and ulines[1]:find("-> Response", 1, true) ~= nil
  )
  check("separator rule present", all_u:find("────", 1, true) ~= nil)
  check("docstring first paragraph at bottom", ulines[#ulines]:find("Spin up the demo service") ~= nil)
  check("docstring second paragraph hidden when collapsed", not all_u:find("considerable length"))

  -- d expands the docstring, d again collapses
  vim.api.nvim_set_current_win(ts_win)
  vim.api.nvim_feedkeys("d", "x", false)
  local expanded = table.concat(float_lines(), "\n")
  check("d expands full docstring", expanded:find("considerable length") ~= nil)
  vim.api.nvim_feedkeys("d", "x", false)
  check("d collapses again", not table.concat(float_lines(), "\n"):find("considerable length"))

  -- d from a param row jumps to that param's definition in the docstring,
  -- movement inside the section is plain (k = one line, no ledger bounce),
  -- and a second d folds the section and returns to the row it left
  local ts_buf2 = vim.api.nvim_win_get_buf(ts_win)
  local function cursor_text()
    local l = vim.api.nvim_win_get_cursor(ts_win)[1]
    return l, vim.api.nvim_buf_get_lines(ts_buf2, l - 1, l, false)[1] or ""
  end
  for i, l in ipairs(vim.api.nvim_buf_get_lines(ts_buf2, 0, -1, false)) do
    -- the exact row ("· timeout  float"): plain "timeout" also hits the
    -- header and config's timeout_ms child
    if l:find("· timeout ", 1, true) then
      vim.api.nvim_win_set_cursor(ts_win, { i, 0 })
      break
    end
  end
  vim.api.nvim_feedkeys("d", "x", false)
  local dl, dtext = cursor_text()
  check("d jumps to the hovered param's docstring definition", dtext:find("timeout : float", 1, true) ~= nil)
  vim.api.nvim_feedkeys("k", "x", false)
  local kl = vim.api.nvim_win_get_cursor(ts_win)[1]
  check("k inside the docstring moves exactly one line", kl == dl - 1)
  vim.api.nvim_feedkeys("d", "x", false)
  local _, back = cursor_text()
  check("d returns to the param row it left", back:find("timeout", 1, true) ~= nil)
  check("return trip folds the docstring", not table.concat(float_lines(), "\n"):find("Seconds to wait"))

  -- active param (mock always reports 0 → config) renders TypeScopeActive
  local ts_buf = vim.api.nvim_win_get_buf(ts_win)
  local ns = vim.api.nvim_create_namespace("typescope")
  local has_active = false
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(ts_buf, ns, 0, -1, { details = true })) do
    if m[4].hl_group == "TypeScopeActive" then
      has_active = true
    end
  end
  check("active parameter highlighted", has_active)

  -- hint extmark on this call line (earlier opens hinted their own lines)
  local hint_ns = vim.api.nvim_create_namespace("typescope_hint")
  local hrow
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:find("handle = create_server") then
      hrow = i - 1
    end
  end
  local hints = vim.api.nvim_buf_get_extmarks(bufnr, hint_ns, { hrow, 0 }, { hrow, -1 }, {})
  check("hint extmark placed on call line", #hints == 1)

  require("typescope").close()
  check("float closed", #all_floats() == 0)
end

-- resolve cache (U2): reopen reuses the tree — the lazily expanded `returns`
-- children persist; editing the def buffer invalidates
require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
local cached_lines = float_lines()
check("cache reopen: lazy expansion persisted", table.concat(cached_lines or {}, "\n"):find("status") ~= nil)
require("typescope").close()

-- the buster must reach DISK: the mock server greps files, not buffers
-- (real servers get didChange; this desync is mock-only)
vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "# cache-buster comment" })
vim.cmd("silent write")
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if l:find("handle = create_server") then
    vim.api.nvim_win_set_cursor(0, { i, 12 })
  end
end
require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
local fresh = table.concat(float_lines() or {}, "\n")
check("edit invalidates cache: fresh tree, returns collapsed again", fresh:find("returns") ~= nil and not fresh:find("status"))
require("typescope").close()
vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {}) -- restore fixture
vim.cmd("silent write")
require("typescope.resolve").clear_cache()

-- cancellation is explicit: concurrent pipelines (prefetch / open / attach
-- kicks) each own their token; minting one must not stale the others.
-- Regression: LspAttach kicks fired by def-site buffers a pipeline loads
-- were killing that very pipeline under the old global-generation design.
do
  local async = require("typescope.async")
  local a = async.token()
  local b = async.token()
  check("minting a token does not stale others", not async.stale(a) and not async.stale(b))
  async.cancel(a)
  check("cancel stales only its own token", async.stale(a) and not async.stale(b))
end

-- prefetch (warmstart): CursorHold silently fills the resolve cache — no
-- float — so the eventual open() paints warm
do
  local resolve = require("typescope.resolve")
  require("typescope").setup({}) -- registers warmstart autocmds (prefetch on by default)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:find("handle = create_server") then
      vim.api.nvim_win_set_cursor(0, { i, 12 })
    end
  end
  vim.cmd("doautocmd CursorHold")
  vim.wait(2000, function()
    return resolve._cache_count() > 0
  end)
  check("prefetch fills cache with no float", resolve._cache_count() > 0 and float_lines() == nil)

  -- same word again: the suppression key blocks a re-run (cache stays empty)
  resolve.clear_cache()
  vim.cmd("doautocmd CursorHold")
  vim.wait(500)
  check("prefetch suppressed on same word", resolve._cache_count() == 0)

  -- different call: prefetch runs again, and open() serves from the warm cache
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:find("result = update_user") then
      vim.api.nvim_win_set_cursor(0, { i, 12 })
    end
  end
  vim.cmd("doautocmd CursorHold")
  vim.wait(2000, function()
    return resolve._cache_count() > 0
  end)
  check("prefetch runs for a new word", resolve._cache_count() > 0)
  require("typescope").open()
  vim.wait(2000, function()
    return float_lines() ~= nil
  end)
  check("open after prefetch paints from cache", float_lines() ~= nil)
  require("typescope").close()
  resolve.clear_cache()
end

-- insert-mode typing surface (U6): names block listing every param +
-- ONE detail line for the active one, anchored above the cursor (hard rule:
-- cursor line + line below never occluded), never focusable, degradation
-- instead of wrapping, closes on InsertLeave. Overloads never stack — [n/m]
-- badge + silent auto-follow.
do
  -- max_width 72: wide enough for the shape segment (headless columns are 80,
  -- so the default fraction would starve it)
  require("typescope").setup({ insert_mode = { enabled = true }, ui = { max_width = 72 } })
  local function insert_float()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local c = vim.api.nvim_win_get_config(w)
      if c.relative ~= "" and vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "typescope" then
        return w, c
      end
    end
  end
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local col = l:find("create_server%(None")
    if col then
      vim.api.nvim_win_set_cursor(0, { i, col + 14 }) -- inside the parens
    end
  end
  -- insert mode itself is unreachable headless (feedkeys "x!" hangs on the
  -- nested input loop, startinsert never applies mid-script); the module has
  -- no mode checks — its insert-only trigger events are the guard — so the
  -- entry point is driven directly
  require("typescope.insert")._update()
  vim.wait(2000, function()
    return insert_float() ~= nil
  end)
  local iw, ic = insert_float()
  check("insert surface opened", iw ~= nil)
  if iw then
    check("insert float never focusable", ic.focusable == false)
    local ibuf = vim.api.nvim_win_get_buf(iw)
    local ilines = vim.api.nvim_buf_get_lines(ibuf, 0, -1, false)
    -- the detail may wrap: everything below the rule belongs to it
    local rule_at = 0
    for i, l in ipairs(ilines) do
      if l:find("──", 1, true) then
        rule_at = i
      end
    end
    local detail = table.concat(ilines, "\n", rule_at + 1)
    check(
      "signature block is K-header shaped (name, parens, params, return type)",
      ilines[1]:find("create_server(config, timeout)", 1, true) ~= nil and ilines[1]:find("-> Response", 1, true) ~= nil
    )
    check(
      "detail shows the active param with its shape",
      detail:find("config") ~= nil
        and detail:find("ServerConfig") ~= nil
        and detail:find("≈", 1, true) ~= nil
        and detail:find("{host", 1, true) ~= nil
    )
    check("no docstring while typing", not table.concat(ilines, "\n"):find("Spin up"))
    check("typing surface wears the shared border", ic.border ~= nil and ic.border ~= "none")
    -- hard rule: SW row 0 → in a REAL UI the whole float (border included)
    -- ends on the line above the cursor. Headless attaches no UI and never
    -- applies anchor geometry, so screen positions can't be asserted here —
    -- assert the normalized config instead (get_config rewrites
    -- relative=cursor to win coords: SW anchored at the cursor's window row)
    check(
      "typing surface anchors SW at the cursor row (real UI: ends on the line above)",
      ic.anchor == "SW" and ic.row == vim.fn.winline() - 1
    )
    -- the param name is the active-param highlight (always, by construction)
    local ns = vim.api.nvim_create_namespace("typescope")
    local has_active = false
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(ibuf, ns, 0, -1, { details = true })) do
      if m[4].hl_group == "TypeScopeActive" then
        has_active = true
      end
    end
    check("typing surface highlights the active param", has_active)
    vim.cmd("doautocmd InsertLeave")
    check("insert float closes on InsertLeave", insert_float() == nil)
  end

  -- overloads: badge [n/m] on the one line, silent auto-follow on arity
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:find("fetched = fetch") then
      vim.api.nvim_win_set_cursor(0, { i, 16 }) -- inside fetch( parens
    end
  end
  require("typescope.insert")._update()
  vim.wait(2000, function()
    return insert_float() ~= nil
  end)
  local ow = insert_float()
  check("insert overload float opened", ow ~= nil)
  if ow then
    local oall = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ow), 0, -1, false), "\n")
    check("typing surface carries the overload badge [1/2]", oall:find("%[1/2%]") ~= nil)
    check("typing surface shows one overload only", oall:find("key") ~= nil and not oall:find("%[2/2%]"))
    check("typing surface keeps the heuristic example at full width", oall:find("e%.g%.") ~= nil)

    -- auto-follow: adding a second argument bumps the mock's arity-based
    -- activeSignature; the typing surface silently swaps its badge. The line must
    -- reach DISK — the mock reads files, not buffers (didChange desync is
    -- mock-only, same as the cache-buster test above).
    local frow
    for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if l:find("fetched = fetch") then
        frow = i
      end
    end
    vim.api.nvim_buf_set_lines(bufnr, frow - 1, frow, false, { 'fetched = fetch("a", "b")' })
    vim.cmd("silent write")
    vim.api.nvim_win_set_cursor(0, { frow, 21 }) -- after the comma
    require("typescope.insert")._update()
    local followed = vim.wait(3000, function()
      local ww = insert_float()
      if not ww then
        return false
      end
      -- overload 2 has 4 params, so the badge rides the LAST line under a
      -- names block
      local h = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ww), 0, -1, false), "\n")
      return h:find("%[2/2%]") ~= nil
    end, 100)
    check("insert auto-follows activeSignature to overload 2", followed)
    local fw = insert_float()
    if fw then
      local flines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(fw), 0, -1, false)
      check(
        "overload 2's names block lists its params",
        flines[1]:find("key") ~= nil and flines[1]:find("policy") ~= nil and flines[1]:find("mode") ~= nil
      )
    end
    vim.api.nvim_buf_set_lines(bufnr, frow - 1, frow, false, { "fetched = fetch(1)" })
    vim.cmd("silent write")
    vim.cmd("doautocmd InsertLeave")

    -- client-side matching (h8h) in the typing surface: cursor inside a string arg,
    -- where the mock's word-at answer yields no signatureHelp signal worth
    -- trusting (activeSignature=0 via the callee fallback) — the literal
    -- kind still picks the sink: str overload
    for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if l:find("attached = attach") then
        vim.api.nvim_win_set_cursor(0, { i, 20 }) -- inside "app.log"
      end
    end
    require("typescope.insert")._update()
    local str_matched = vim.wait(3000, function()
      local ww = insert_float()
      if not ww then
        return false
      end
      local h = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ww), 0, -1, false), "\n")
      return h:find("%[2/2%]") ~= nil
    end, 100)
    check("typing surface client-matches the str overload inside a string arg", str_matched)
    vim.cmd("doautocmd InsertLeave")
  end

  -- a narrow budget wraps the detail (nothing dropped, every line within
  -- budget) — driven through insert_mode.max_width, the surface's own knob
  require("typescope").setup({ insert_mode = { enabled = true, max_width = 28 } })
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:find("fetched = fetch") then
      vim.api.nvim_win_set_cursor(0, { i, 16 })
    end
  end
  require("typescope.insert")._update()
  vim.wait(2000, function()
    return insert_float() ~= nil
  end)
  local nw = insert_float()
  check("insert narrow typing surface opened", nw ~= nil)
  if nw then
    local nlines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(nw), 0, -1, false)
    local nall = table.concat(nlines, "\n")
    local within = true
    for _, l in ipairs(nlines) do
      within = within and vim.api.nvim_strwidth(l) <= 28
    end
    check(
      "narrow typing surface wraps within insert_mode.max_width, keeps everything",
      #nlines > 1 and within and nall:find("e%.g%.") ~= nil and nall:find("key") ~= nil and nall:find("%[1/2%]") ~= nil
    )
    vim.cmd("doautocmd InsertLeave")
  end

  -- an insert cursor just RIGHT of the closing paren is OUTSIDE the call —
  -- the surface must not fire (ve=onemore lets a headless cursor sit there)
  vim.opt.virtualedit = "onemore"
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:find("handle = create_server") then
      vim.api.nvim_win_set_cursor(0, { i, #l }) -- one past the ')'
    end
  end
  require("typescope.insert")._update()
  vim.wait(500)
  check("no surface outside the closing paren", insert_float() == nil)
  vim.opt.virtualedit = ""
  require("typescope").setup({}) -- back to defaults for the remaining tests
end

-- K ledger layout (U6): one-line rows — name | type | short default — with a
-- detail block that follows the cursor once the float is focused
do
  require("typescope").setup({ ui = { layout = "ledger" } })
  vim.api.nvim_win_set_cursor(0, { call_line, 12 })
  require("typescope").open()
  vim.wait(3000, function()
    return float_lines() ~= nil
  end)
  local llines, lw = float_lines()
  check("ledger float opened", llines ~= nil)
  if llines then
    local all = table.concat(llines, "\n")
    local timeout_row, config_row
    for i, l in ipairs(llines) do
      if l:find("timeout") then
        timeout_row = i
      end
      if l:find("config") and not l:find("create_server") then
        config_row = config_row or i
      end
    end
    check("ledger rows are single lines (timeout: type + inline default)", timeout_row ~= nil and llines[timeout_row]:find("float") ~= nil and llines[timeout_row]:find("= 30%.0") ~= nil)
    check("ledger rows carry no expand hints or examples", not all:find("<CR>") and not all:find("localhost"))

    -- focus, rest on the timeout row: the detail block appears under it
    vim.api.nvim_set_current_win(lw)
    vim.api.nvim_win_set_cursor(lw, { timeout_row, 0 })
    vim.cmd("doautocmd CursorMoved")
    local detailed = vim.wait(1000, function()
      local cur = table.concat(float_lines() or {}, "\n")
      return cur:find("│ = 30%.0") ~= nil
    end, 50)
    check("ledger detail block follows the cursor (timeout default)", detailed)
    if detailed then
      -- the detail row itself drops its inline default (the block carries it)
      local cur = float_lines()
      for _, l in ipairs(cur) do
        if l:find("timeout") then
          check("detail row hands its default to the block", not l:find("=30%.0"))
        end
      end
      -- moving to another row swaps the block
      for i, l in ipairs(cur) do
        if l:find("config") and not l:find("create_server") then
          vim.api.nvim_win_set_cursor(lw, { i, 0 })
          break
        end
      end
      vim.cmd("doautocmd CursorMoved")
      local swapped = vim.wait(1000, function()
        return not table.concat(float_lines() or {}, "\n"):find("│ = 30%.0")
      end, 50)
      check("ledger detail block leaves the abandoned row", swapped)

      -- j/k are node motions: from timeout (detail block open under it) j
      -- skips the block's info lines straight to returns; k jumps back to
      -- timeout's primary row
      -- last match: the header line also says "timeout"; the param row wins
      local t2
      for i, l in ipairs(float_lines()) do
        if l:find("timeout") then
          t2 = i
        end
      end
      vim.api.nvim_win_set_cursor(lw, { t2, 0 })
      vim.cmd("doautocmd CursorMoved")
      vim.wait(500, function()
        return table.concat(float_lines() or {}, "\n"):find("│ = 30%.0") ~= nil
      end, 50)
      local function cursor_line()
        return vim.api.nvim_buf_get_lines(
          vim.api.nvim_win_get_buf(lw),
          vim.api.nvim_win_get_cursor(lw)[1] - 1,
          vim.api.nvim_win_get_cursor(lw)[1],
          false
        )[1] or ""
      end
      vim.api.nvim_feedkeys("j", "x", false)
      check("j skips info lines to the next node", cursor_line():find("returns") ~= nil)
      vim.api.nvim_feedkeys("k", "x", false)
      check("k jumps back to the previous node's primary row", cursor_line():find("timeout") ~= nil)
    end
    require("typescope").close()
  end
  require("typescope").setup({})
end

-- hover() takeover: function symbol → typescope; non-function → plain hover
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if l:find("handle = create_server") then
    vim.api.nvim_win_set_cursor(0, { i, 12 })
  end
end
require("typescope").hover()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
check("hover() on function opens typescope", float_lines() ~= nil)
require("typescope").close()

vim.api.nvim_win_set_cursor(0, { 1, 6 }) -- 'dataclasses' in the import line
require("typescope").hover()
vim.wait(1000, function()
  return #all_floats() > 0
end)
local plain_hover = #all_floats() > 0 and float_lines() == nil
check("hover() on non-function falls back to plain hover", plain_hover)
for _, w in ipairs(all_floats()) do
  pcall(vim.api.nvim_win_close, w, true)
end

-- ui.focus: explicit opens enter the float by default; focus = false (per
-- call or via config) restores the momentary hover convention
local focus_srcwin = vim.api.nvim_get_current_win()
local function focus_open(opts)
  require("typescope").close()
  vim.api.nvim_set_current_win(focus_srcwin)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:find("handle = create_server") then
      vim.api.nvim_win_set_cursor(focus_srcwin, { i, 12 })
    end
  end
  require("typescope").open(opts)
  vim.wait(2000, function()
    return float_lines() ~= nil
  end)
  local _, w = float_lines()
  return w
end

local fw = focus_open()
check("ui.focus default: float opens focused", fw ~= nil and vim.api.nvim_get_current_win() == fw)
check("ui.focus default: cursorline armed", fw ~= nil and vim.wo[fw].cursorline)

fw = focus_open({ focus = false })
check("focus=false: source window keeps focus", fw ~= nil and vim.api.nvim_get_current_win() == focus_srcwin)

require("typescope").open() -- second open focuses the momentary float
check("focus=false: second open() focuses the float", fw ~= nil and vim.api.nvim_get_current_win() == fw)
check("focus=false: cursorline armed on focus", fw ~= nil and vim.wo[fw].cursorline)

require("typescope").setup({ ui = { focus = false } })
fw = focus_open()
check("ui.focus=false config: open() stays momentary", fw ~= nil and vim.api.nvim_get_current_win() == focus_srcwin)
require("typescope").close()
require("typescope").setup({})

-- hover-backed evaluated leaves: alias annotations decorate with the
-- evaluated type; unannotated params show pyright's inference
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if l:find("configured = configure") then
    vim.api.nvim_win_set_cursor(0, { i, 14 })
  end
end
require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
local lines6 = float_lines()
check("evaluated-leaf float opened", lines6 ~= nil)
if lines6 then
  local all6 = table.concat(lines6, "\n")
  check("alias leaf keeps declared name", all6:find("LoopMode") ~= nil)
  check("alias leaf decorated with evaluated type", all6:find("≈", 1, true) ~= nil and all6:find("Literal") ~= nil)
  local count_ok = false
  for _, l in ipairs(lines6) do
    if l:find("count") and l:find("≈ int", 1, true) and not l:find("Any") then
      count_ok = true
    end
  end
  check("unannotated param shows inferred type, Any suppressed", count_ok)
end
require("typescope").close()

-- alias expansion: `data: Payload` where Payload = UserRecord resolves
-- through the alias transparently — fields attach, alias name stays displayed
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if l:find("sent = send") then
    vim.api.nvim_win_set_cursor(0, { i, 8 })
  end
end
require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
local lines8 = float_lines()
check("alias-expansion float opened", lines8 ~= nil)
if lines8 then
  local all8 = table.concat(lines8, "\n")
  check("alias name kept as vocabulary", all8:find("Payload") ~= nil)
  check("fields resolved through alias", all8:find("email") ~= nil and all8:find("age") ~= nil)
  check("badges survive the alias hop", all8:find("NotRequired") ~= nil)
end
require("typescope").close()

-- overloads (U4): sibling @overload defs render as stacked groups — active
-- expanded, others collapsed, [n/m] in the header
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if l:find("fetched = fetch") then
    vim.api.nvim_win_set_cursor(0, { i, 11 })
  end
end
require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
local lines9, ov_win = float_lines()
check("overload float opened", lines9 ~= nil)
if lines9 then
  local all9 = table.concat(lines9, "\n")
  check("overload header carries [1/2]", lines9[1]:find("%[1/2%]") ~= nil)
  check("both overload groups stacked", all9:find("%[1/2%]") ~= nil and all9:find("%[2/2%]") ~= nil)
  check("active overload expanded (key: int visible)", all9:find("int") ~= nil)
  check("inactive overload collapsed (its default hidden)", not all9:find("auto"))
  -- expanding the second group reveals its params
  vim.api.nvim_set_current_win(ov_win)
  for i, l in ipairs(float_lines()) do
    if l:find("%[2/2%]") then
      vim.api.nvim_win_set_cursor(ov_win, { i, 0 })
      break
    end
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  check("second overload expands to its params", table.concat(float_lines(), "\n"):find("auto") ~= nil)

  -- lazy params INSIDE an overload group must actually resolve on expand
  -- (regression: a still-attached _lazy hook swallowed the whole recurse
  -- fallback and expanding did nothing)
  -- the group row's shape display also says "policy=…" — target the param
  -- ROW (name followed by its RetryPolicy annotation), not the group row
  for i, l in ipairs(float_lines()) do
    if l:find("policy%s") and l:find("RetryPolicy") then
      vim.api.nvim_win_set_cursor(ov_win, { i, 0 })
      break
    end
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  vim.wait(2000, function()
    return table.concat(float_lines() or {}, "\n"):find("max_attempts") ~= nil
  end)
  check("lazy overload param expands to class structure", table.concat(float_lines(), "\n"):find("max_attempts") ~= nil)

  -- evaluation-only expansion (alias to a builtins-only RHS): the ≈ view
  -- folds like a branch — h collapses the node itself, NOT the parent group
  for i, l in ipairs(float_lines()) do
    if l:find("mode%s") and l:find("LoopMode") then
      vim.api.nvim_win_set_cursor(ov_win, { i, 0 })
      break
    end
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  vim.wait(2000, function()
    return table.concat(float_lines() or {}, "\n"):find("Literal") ~= nil
  end)
  check("evaluation-only expand decorates with ≈", table.concat(float_lines(), "\n"):find("Literal") ~= nil)
  for i, l in ipairs(float_lines()) do
    if l:find("mode%s") and l:find("LoopMode") then
      vim.api.nvim_win_set_cursor(ov_win, { i, 0 })
      break
    end
  end
  vim.api.nvim_feedkeys("h", "x", false)
  local after_h = table.concat(float_lines(), "\n")
  check("h folds the ≈ view, not the parent", not after_h:find("Literal") and after_h:find("max_attempts") ~= nil)
  vim.api.nvim_feedkeys("l", "x", false)
  check("l re-expands the ≈ view without re-resolving", table.concat(float_lines(), "\n"):find("Literal") ~= nil)
end
require("typescope").close()

-- class under cursor: show the type's own structure (incl. inheritance)
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  local col = l:find("config: ServerConfig")
  if col then
    vim.api.nvim_win_set_cursor(0, { i, col + 8 }) -- on 'ServerConfig'
  end
end
require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
local lines7 = float_lines()
check("class-hover float opened", lines7 ~= nil)
if lines7 then
  local all7 = table.concat(lines7, "\n")
  check(
    "class root with category + ancestry header",
    lines7[1]:find("ServerConfig") and lines7[1]:find("(dataclass ← BaseConfig)", 1, true)
  )
  check("class fields shown", all7:find("host") and all7:find("retry"))
  check("class inheritance merged", all7:find("env") and all7:find("↑BaseConfig", 1, true))
  check("class docstring section at bottom", lines7[#lines7]:find("Connection settings container") ~= nil)
end
require("typescope").close()

-- annotation normalization: old typing syntax → modern display
do
  local py = require("typescope.extract.python")
  local src = 'def f(a: typing.Optional[str], b: typing.Union["X", typing.Callable, str],'
    .. " c: typing.List[int], d: Optional[Union[int, str]], e: typing.Type[asyncio.Protocol]) -> None: ..."
  local info = py.function_info(src, 0, 4)
  local want = {
    a = "str | None",
    b = "X | Callable | str",
    c = "list[int]",
    d = "int | str | None",
    e = "type[asyncio.Protocol]",
  }
  for _, p in ipairs(info.params) do
    local got = py.annotation(src, p.type_node).display
    check(("normalize %s -> %s"):format(p.name, want[p.name]), got == want[p.name])
    if got ~= want[p.name] then
      print(("  got: %q"):format(got))
    end
  end
end

-- active_param: name-based, immune to `*` separator entries (uvicorn case)
do
  local lspu = require("typescope.lsp")
  local star_sig = {
    signatures = {
      {
        label = 'run(app, *, host: str = "0.0.0.0", port: int = 8000)',
        parameters = {
          { label = "app" },
          { label = "*" },
          { label = 'host: str = "0.0.0.0"' },
          { label = "port: int = 8000" },
        },
        activeParameter = 2,
      },
    },
    activeSignature = 0,
  }
  check("active param after * resolves to host, not port", lspu.active_param(star_sig) == "host")
  star_sig.signatures[1].activeParameter = 1
  check("bare * separator yields nil", lspu.active_param(star_sig) == nil)
  local offset_sig = {
    signatures = {
      { label = "f(count: int)", parameters = { { label = { 2, 12 } } }, activeParameter = 0 },
    },
  }
  check("offset-form labels resolve", lspu.active_param(offset_sig) == "count")
end

-- LLM examples (E): fake Ollama server serves canned literals; the whole
-- keymap → spinner → request → parse → re-render path runs for real
local fake_port
do
  local uv = vim.uv
  local server = uv.new_tcp()
  _G.__typescope_fake_ollama = server -- anchor: GC of the handle closes the socket
  server:bind("127.0.0.1", 0)
  fake_port = server:getsockname().port
  server:listen(16, function()
    local sock = uv.new_tcp()
    server:accept(sock)
    sock:read_start(function(_, chunk)
      if chunk then
        -- streamed transport: JSON-lines, one object per chunk, done=true
        -- last. The literal newlines in the text are escaped by json.encode,
        -- so each object still occupies exactly one line of the framing.
        local body = vim.json.encode({
          response = 'config.host = "llm-host.example.io/gateway/v2/ingest?region=us-west-2"\nconfig.port = 8443\nconfig.timeout_ms = 250\ntimeout = 12.5',
          done = false,
        }) .. "\n" .. vim.json.encode({ response = "", done = true }) .. "\n"
        sock:write(
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body
        )
        sock:shutdown()
        sock:close()
      end
    end)
  end)
end

-- ui.max_width is a FRACTION of editor width, and a headless 80-column
-- editor caps the float at 40 — which is what the ledger already needs, so
-- the float opens pinned at its ceiling and nothing can grow. Widen the
-- editor so the landing frame has somewhere to go; restored below.
local prev_columns = vim.o.columns
vim.o.columns = 200
require("typescope").setup({ ollama = { enabled = true, port = fake_port, timeout_ms = 3000 } })
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if l:find("handle = create_server") then
    vim.api.nvim_win_set_cursor(0, { i, 12 })
  end
end
require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
local _, llm_win = float_lines()
check("float for LLM test opened", llm_win ~= nil)
if llm_win then
  vim.api.nvim_set_current_win(llm_win)
  vim.api.nvim_feedkeys("E", "x", false)
  -- wait for BOTH: values uncover progressively as the reveal's blocks fall
  -- (38c), so the first one on screen doesn't mean the row has settled
  -- the float opens into its new width rather than snapping there, so sample
  -- what the window is actually showing while the blocks fall
  local widths = {}
  local function sample()
    widths[#widths + 1] = vim.api.nvim_win_get_config(llm_win).width
  end
  vim.wait(4000, function()
    sample()
    local now = table.concat(float_lines() or {}, "\n")
    return now:find("llm%-host") ~= nil and now:find("8443") ~= nil
  end, 20)
  -- values become legible partway through the grow, so keep sampling past the
  -- predicate or the tail of the ease is never seen
  vim.wait(600, function()
    sample()
    return false
  end, 20)
  local all9 = table.concat(float_lines() or {}, "\n")
  check("LLM values rendered after E", all9:find("llm%-host") ~= nil and all9:find("8443") ~= nil)
  -- >2 distinct widths means it eased; exactly 2 (old width, new width) is the
  -- single-frame snap this replaced
  local lo, hi = math.huge, 0
  for _, w in ipairs(widths) do
    lo, hi = math.min(lo, w), math.max(hi, w)
  end
  check("the float grows into the width the landed values need", hi > lo)
  local title_ok = false
  local cfg9 = vim.api.nvim_win_get_config(llm_win)
  if cfg9.title and cfg9.title[1] and cfg9.title[1][1]:find("typescope") then
    title_ok = true
  end
  check("spinner restored the title", title_ok)
end
require("typescope").close()
vim.o.columns = prev_columns

-- silent ollama (accepts, never answers): stall → auto-retry → honest stall
-- message, not "unreachable". Cache cleared first or the E press is served
-- from the previous test's values and no request ever fires.
--
-- Timing: curl's low-speed check trips at --speed-time + ~2.1s fixed overhead
-- (measured), so timeout_ms=1000 is ~4.1s per attempt and ~8.2s across the
-- retry. The wait below has to clear that, not the nominal 1s.
require("typescope.examples")._clear_llm_cache()
local silent_port
do
  local uv = vim.uv
  local server = uv.new_tcp()
  _G.__typescope_silent_ollama = server -- anchor against GC (see above)
  server:bind("127.0.0.1", 0)
  silent_port = server:getsockname().port
  server:listen(16, function()
    local sock = uv.new_tcp()
    server:accept(sock)
    sock:read_start(function() end) -- swallow the request, never respond
  end)
end
require("typescope").setup({ ollama = { enabled = true, port = silent_port, timeout_ms = 1000 } })
require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
local _, slow_win = float_lines()
check("float for timeout test opened", slow_win ~= nil)
if slow_win then
  local captured
  local orig_notify = vim.notify
  vim.notify = function(msg, ...)
    captured = msg
    return orig_notify(msg, ...)
  end
  vim.api.nvim_set_current_win(slow_win)
  vim.api.nvim_feedkeys("E", "x", false)
  -- Generous on purpose: ~1s warmup probe, then 4.1s + 4.1s across the retry,
  -- and the whole thing shifts under load. A tight window here fails by
  -- arriving late, not by being wrong, which is the worst kind of red.
  vim.wait(30000, function()
    return captured ~= nil
  end)
  vim.notify = orig_notify
  check(
    "stall reported as a stall (after one retry), not unreachable",
    captured ~= nil and captured:find("went silent") ~= nil and captured:find("twice") ~= nil,
    tostring(captured)
  )
end
require("typescope").close()

-- unreachable ollama: E falls back gracefully, heuristics stay
require("typescope.examples")._clear_llm_cache()
require("typescope").setup({ ollama = { enabled = true, port = 1, timeout_ms = 1000 } })
require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
local _, dead_win = float_lines()
check("float for fallback test opened", dead_win ~= nil)
if dead_win then
  vim.api.nvim_set_current_win(dead_win)
  vim.api.nvim_feedkeys("E", "x", false)
  vim.wait(3000, function()
    local c = vim.api.nvim_win_get_config(dead_win)
    return c.title and c.title[1] and c.title[1][1]:find("typescope") ~= nil
  end)
  local all10 = table.concat(float_lines() or {}, "\n")
  check("heuristics survive unreachable ollama", all10:find("localhost") ~= nil)
end
require("typescope").close()

-- example_mode = "llm": generation fires automatically on open, no E needed
require("typescope").setup({
  example_mode = "llm",
  ollama = { enabled = true, port = fake_port, timeout_ms = 3000 },
})
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if l:find("handle = create_server") then
    vim.api.nvim_win_set_cursor(0, { i, 12 })
  end
end
local auto_msgs = {}
local auto_orig_notify = vim.notify
vim.notify = function(m, ...)
  table.insert(auto_msgs, tostring(m))
  return auto_orig_notify(m, ...)
end
require("typescope").open()
vim.wait(6000, function()
  return table.concat(float_lines() or {}, "\n"):find("llm%-host") ~= nil
end)
vim.notify = auto_orig_notify
local auto = table.concat(float_lines() or {}, "\n")
check("auto LLM values render without pressing E", auto:find("llm%-host") ~= nil)
if not auto:find("llm%-host") then
  print("  DEBUG float:\n" .. auto)
  print("  DEBUG notifies: " .. vim.inspect(auto_msgs))
end
require("typescope").close()

-- A cancelled lazy expand must leave the node retryable.
--
-- resolve.recurse clears node._lazy up front, deliberately: attach_type's
-- enrichment fallback is gated on the hook being absent. If the token is
-- cancelled mid-chase the hook used to stay cleared, and since `loaded` is
-- still false and `source` is still set the row kept its expander marker while
-- recurse_into had nothing to fire — a silent no-op, handed back by the
-- resolve cache on every reopen of that symbol.
--
-- Cancelling BEFORE the call rather than racing one in flight: attach_type
-- checks staleness first thing, so this lands in the same branch every run
-- instead of depending on how fast the mock answers.
do
  local model = require("typescope.model")
  local async = require("typescope.async")
  local resolve = require("typescope.resolve")
  local lsp = require("typescope.lsp")
  local client = lsp.client_for(bufnr)
  local uri = vim.uri_from_fname(fixture_dir .. "/sample.py")

  -- `ServerConfig` sits at line 20 of the fixture (0-based 19); a beyond-depth
  -- placeholder points its ref there and carries no children of its own
  local function lazy_node()
    local n = model.new({
      name = "config",
      kind = "param",
      type = { raw = "ServerConfig", display = "ServerConfig", category = "generic" },
      loaded = false,
      source = { uri = uri, range = { start = { line = 19, character = 0 } } },
    })
    n._lazy = {
      uri = uri,
      refs = { { name = "ServerConfig", row = 19, col = 6 } },
      ancestry = {},
      impl = require("typescope.extract").get("python"),
    }
    return n
  end

  local cancelled = lazy_node()
  local dead_token = async.token()
  async.cancel(dead_token)
  resolve.recurse(client, cancelled, dead_token, function() end)
  vim.wait(200, function()
    return not cancelled.state.loading
  end)
  check("a cancelled expand keeps its lazy hook", cancelled._lazy ~= nil)
  check("...and is not left mid-load", cancelled.state.loading == false)
  check("...still unloaded, so the retry actually chases", cancelled.state.loaded == false)
  check("...with no half-built children to duplicate", #cancelled.children == 0)

  -- the point of restoring the hook: expanding again has to WORK
  local done = false
  resolve.recurse(client, cancelled, async.token(), function()
    done = true
  end)
  vim.wait(2000, function()
    return done
  end)
  check("...and a later expand resolves it for real", #cancelled.children > 0)
  if #cancelled.children == 0 then
    print("  DEBUG: loaded=" .. tostring(cancelled.state.loaded) .. " lazy=" .. tostring(cancelled._lazy ~= nil))
  else
    local names = {}
    for _, c in ipairs(cancelled.children) do
      table.insert(names, c.name)
    end
    check("...into ServerConfig's own fields", vim.tbl_contains(names, "host") and vim.tbl_contains(names, "port"))
  end
end

-- setup() has to be re-entrant in BOTH directions.
--
-- config.setup says "safe to call more than once", and it is — but the wiring
-- around it only ever added autocmds. Turning a feature back off left its
-- group installed and firing: switching trigger from "hover" to "manual" kept
-- auto-opening the float on CursorHold. Anyone toggling at runtime hits this,
-- and so does a plugin manager that merges `opts` and then also runs a
-- `config` function.
--
-- Runs last on purpose: it rewrites the global config, so nothing after it
-- could trust what it left behind.
do
  local ts = require("typescope")
  local function autocmds(group)
    local ok, list = pcall(vim.api.nvim_get_autocmds, { group = group })
    return ok and #list or 0
  end

  ts.setup({ trigger = "hover" })
  check("trigger = hover installs the CursorHold autocmd", autocmds("TypeScopeHover") > 0)
  ts.setup({ trigger = "manual" })
  check("...and switching back to manual takes it down", autocmds("TypeScopeHover") == 0)
  ts.setup({ trigger = "hover" })
  check("...and it comes back when asked again", autocmds("TypeScopeHover") > 0)

  ts.setup({ insert_mode = { enabled = true } })
  check("insert_mode on installs the typing-surface autocmds", autocmds("TypeScopeInsert") > 0)
  ts.setup({ insert_mode = { enabled = false } })
  check("...and turning it off takes them down", autocmds("TypeScopeInsert") == 0)

  -- warmstart already cleared its own group; assert it stays that way, since
  -- the other two now follow its pattern
  ts.setup({ prefetch = true, trigger = "manual" })
  local with_prefetch = autocmds("TypeScopeWarmstart")
  ts.setup({ prefetch = false, trigger = "manual" })
  check("prefetch off drops its CursorHold watcher", autocmds("TypeScopeWarmstart") < with_prefetch)

  ts.setup({}) -- leave the config at defaults
end

print(failures == 0 and "ALL PASS" or (failures .. " FAILURES"))
