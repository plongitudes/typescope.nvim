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

-- insert-mode typing surface (U3): budget-reduced float inside call parens —
-- header + collapsed roots, no docstring, never focusable, active param
-- follows signatureHelp, closes on InsertLeave
do
  require("typescope").setup({ insert_mode = { enabled = true } })
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
    local alli = table.concat(ilines, "\n")
    check("insert header shows call shape", ilines[1]:find("create_server(config", 1, true) ~= nil)
    check("insert roots collapsed (no class fields)", not alli:find("host"))
    check("no docstring while typing", not alli:find("Spin up"))
    -- active param: mock always reports parameter 0 → config row highlighted
    local ns = vim.api.nvim_create_namespace("typescope")
    local has_active = vim.wait(3000, function()
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(ibuf, ns, 0, -1, { details = true })) do
        if m[4].hl_group == "TypeScopeActive" then
          return true
        end
      end
      return false
    end, 100)
    check("insert active param follows signatureHelp", has_active)
    vim.cmd("doautocmd InsertLeave")
    check("insert float closes on InsertLeave", insert_float() == nil)
  end

  -- overloads in the typing surface (U4): never stacked — the active
  -- overload's params only, [n/m] in the header
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
    local obuf = vim.api.nvim_win_get_buf(ow)
    local olines = vim.api.nvim_buf_get_lines(obuf, 0, -1, false)
    local allo = table.concat(olines, "\n")
    check("insert overload header [1/2]", olines[1]:find("%[1/2%]") ~= nil)
    check("insert shows single overload, not stacked", not allo:find("%[2/2%]"))

    -- auto-follow: adding a second argument bumps the mock's arity-based
    -- activeSignature; the display silently swaps to overload 2. The line
    -- must reach DISK — the mock reads files, not buffers (didChange desync
    -- is mock-only, same as the cache-buster test above).
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
      local h = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ww), 0, -1, false)[1]
      return h:find("%[2/2%]") ~= nil
    end, 100)
    check("insert auto-follows activeSignature to overload 2", followed)
    local ww = insert_float()
    if ww then
      local swapped = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ww), 0, -1, false), "\n")
      check("swapped display shows overload 2's default param", swapped:find("auto") ~= nil)
    end
    vim.api.nvim_buf_set_lines(bufnr, frow - 1, frow, false, { "fetched = fetch(1)" })
    vim.cmd("silent write")
    vim.cmd("doautocmd InsertLeave")
  end
  require("typescope").setup({}) -- back to defaults for the remaining tests
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
        local body = vim.json.encode({
          response = 'config.host = "llm-host.example.io"\nconfig.port = 8443\nconfig.timeout_ms = 250\ntimeout = 12.5',
        })
        sock:write(
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body
        )
        sock:shutdown()
        sock:close()
      end
    end)
  end)
end

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
  vim.wait(4000, function()
    return table.concat(float_lines() or {}, "\n"):find("llm%-host") ~= nil
  end)
  local all9 = table.concat(float_lines() or {}, "\n")
  check("LLM values rendered after E", all9:find("llm%-host") ~= nil and all9:find("8443") ~= nil)
  local title_ok = false
  local cfg9 = vim.api.nvim_win_get_config(llm_win)
  if cfg9.title and cfg9.title[1] and cfg9.title[1][1]:find("typescope") then
    title_ok = true
  end
  check("spinner restored the title", title_ok)
end
require("typescope").close()

-- silent ollama (accepts, never answers): timeout → auto-retry → honest
-- timeout message, not "unreachable". Cache cleared first or the E press is
-- served from the previous test's values and no request ever fires.
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
  vim.wait(6000, function()
    return captured ~= nil
  end)
  vim.notify = orig_notify
  check(
    "timeout reported as timeout (after one retry), not unreachable",
    captured ~= nil and captured:find("timed out twice") ~= nil
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

print(failures == 0 and "ALL PASS" or (failures .. " FAILURES"))
