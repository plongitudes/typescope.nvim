-- Golden-render tests: fixture trees through the pure renderer, asserting the
-- exact displayed lines, node mapping, highlight byte offsets, and injection
-- spans. Run headless:
--   nvim --headless --clean --cmd "set rtp+=." -c "luafile tests/test_render.lua" -c "qa!"

local model = require("typescope.model")
local render = require("typescope.render")
local styles = require("typescope.styles")

local failures = 0
local function check(desc, cond)
  print((cond and "PASS " or "FAIL ") .. desc)
  if not cond then
    failures = failures + 1
  end
end

-- Distinct ladder rungs present in a line. Plain find per rung, NOT a pattern
-- class: Lua patterns are byte-based and "[▁▂▃]" matches individual UTF-8
-- bytes rather than characters.
local RUNGS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local function rung_count(line)
  local n = 0
  for _, ch in ipairs(RUNGS) do
    if line:find(ch, 1, true) then
      n = n + 1
    end
  end
  return n
end

local function eq_lines(desc, got, want)
  local ok = #got == #want
  if ok then
    for i, l in ipairs(want) do
      if got[i] ~= l then
        ok = false
      end
    end
  end
  check(desc, ok)
  if not ok then
    for i = 1, math.max(#got, #want) do
      if got[i] ~= want[i] then
        print(("  L%d got >%s< want >%s<"):format(i, tostring(got[i]), tostring(want[i])))
      end
    end
  end
end

-- one tree exercising: nesting, defaults, badges, examples, unresolved
-- indicator, collapsed root with hint, return keyword
local function tree()
  return {
    model.new({
      name = "config",
      kind = "param",
      expanded = true,
      type = { display = "ServerConfig", category = "dataclass" },
      children = {
        { name = "host", type = { display = "str", category = "builtin" }, example = { heuristic = '"localhost"' } },
        {
          name = "retry",
          expanded = true,
          type = { display = "RetryPolicy", category = "pydantic" },
          children = {
            { name = "max_attempts", type = { display = "int", category = "builtin" }, default = "3" },
          },
        },
        {
          name = "timeout_ms",
          type = { display = "int | None", category = "generic" },
          default = "None",
          badge = "NotRequired",
        },
      },
    }),
    model.new({ name = "opaque", kind = "param", type = { display = "Mystery", category = "unresolved" } }),
    model.new({
      name = "returns",
      kind = "return",
      type = { display = "Response", category = "dataclass" },
      children = { { name = "status", type = { display = "int", category = "builtin" } } },
    }),
  }
end

local function opts(over)
  return vim.tbl_extend("force", {
    style = styles.get("unicode"),
    max_width = 60,
    align = "left",
    show_examples = true,
    example_kind = "heuristic",
  }, over or {})
end

-- 1. left-aligned unicode, examples on
eq_lines("left/unicode/examples", render.render(tree(), opts()).lines, {
  '▾ config   ServerConfig',
  '  ├─ · host        str  "localhost"',
  '  ├─ ▾ retry       RetryPolicy',
  '  │ └─ · max_attempts  int = 3',
  '  └─ · timeout_ms  int | None NotRequired = None',
  '· opaque   Mystery [?]',
  '▸ returns  Response  (<CR> to expand)',
})

-- 2. right-aligned rounded, examples off
eq_lines(
  "right/rounded",
  render.render(tree(), opts({ style = styles.get("rounded"), align = "right", show_examples = false })).lines,
  {
    ' ▾ config  ServerConfig',
    '  ├─       · host  str',
    '  ├─      ▾ retry  RetryPolicy',
    '  │ ╰─ · max_attempts  int = 3',
    '  ╰─ · timeout_ms  int | None NotRequired = None',
    ' · opaque  Mystery [?]',
    '▸ returns  Response  (<CR> to expand)',
  }
)

-- 3. wrap at 40: hanging indent, tree bars carried onto continuations
eq_lines(
  "wrap-40 hanging indent",
  render.render(tree(), opts({ style = styles.get("rounded"), max_width = 40, show_examples = false })).lines,
  {
    '▾ config   ServerConfig',
    '  ├─ · host        str',
    '  ├─ ▾ retry       RetryPolicy',
    '  │ ╰─ · max_attempts  int = 3',
    '  ╰─ · timeout_ms  int | None',
    '                    NotRequired = None',
    '· opaque   Mystery [?]',
    '▸ returns  Response  (<CR> to expand)',
  }
)

-- 4. minimal style: indentation only
eq_lines(
  "minimal style",
  render.render(tree(), opts({ style = styles.get("minimal"), show_examples = false })).lines,
  {
    '- config   ServerConfig',
    '      host        str',
    '    - retry       RetryPolicy',
    '        max_attempts  int = 3',
    '      timeout_ms  int | None NotRequired = None',
    '  opaque   Mystery [?]',
    '+ returns  Response  (<CR> to expand)',
  }
)

-- 5. node mapping: dotted-path ids, grandchildren rooted correctly
local r = render.render(tree(), opts())
local map_want = {
  "config",
  "config.host",
  "config.retry",
  "config.retry.max_attempts",
  "config.timeout_ms",
  "opaque",
  "returns",
}
local map_ok = true
for i, want in ipairs(map_want) do
  if r.line_to_node[i] ~= want then
    map_ok = false
    print(("  map L%d got %s want %s"):format(i, tostring(r.line_to_node[i]), want))
  end
end
check("line_to_node dotted ids (incl. grandchild)", map_ok)

-- 6. highlight byte offsets survive multibyte chrome (▾ is 3 bytes)
local h1, h2, h3 = r.highlights[1], r.highlights[2], r.highlights[3]
check(
  "highlight byte offsets over multibyte chrome",
  h1.group == "TypeScopeChrome"
    and h1.col_start == 0
    and h1.col_end == 4
    and h2.group == "TypeScopeParam" -- params match @variable.parameter (2026-08-01)
    and h2.col_start == 4
    and h2.col_end == 10
    and h3.group == "TypeScopeType"
    and h3.col_start == 13
)

-- 7. injection spans: types/defaults replace, examples overlay, unsplit only
local kinds = {}
for _, ij in ipairs(r.ts_injections) do
  kinds[ij.text] = ij.mode
end
check(
  "injection modes (replace for types/defaults, overlay for examples)",
  kinds["ServerConfig"] == "replace"
    and kinds["3"] == "replace"
    and kinds['"localhost"'] == "overlay"
)
-- a genuinely split annotation must not inject (fragments aren't parseable);
-- its unsplit default still does
local wide = render.render({
  model.new({
    name = "handlers",
    kind = "param",
    type = {
      display = "dict[str, Callable[[Request, Session], Awaitable[Response | None]]]",
      category = "generic",
    },
    default = "None",
  }),
}, opts({ max_width = 40, show_examples = false }))
local split_injected, default_injected = false, false
for _, ij in ipairs(wide.ts_injections) do
  if ij.text:find("Callable", 1, true) then
    split_injected = true
  end
  if ij.text == "None" then
    default_injected = true
  end
end
check("split spans do not inject; unsplit defaults still do", not split_injected and default_injected)

-- 8b. atomic segments (origin/badges) never split mid-word when wrapping
eq_lines(
  "atomic origin tag jumps whole to continuation",
  render.render({
    model.new({
      name = "px",
      kind = "param",
      expanded = true,
      type = { display = "Wrap", category = "dataclass" },
      children = {
        {
          name = "proxy",
          type = {
            display = "ClassVar[dict[weakref.ref[Any], weakref.ref[Proxy[Any]]]]",
            category = "generic",
          },
          origin = "ReversibleProxy",
          default = "{}",
        },
      },
    }),
  }, opts({ style = styles.get("rounded"), max_width = 44, show_examples = false })).lines,
  {
    '▾ px  Wrap',
    '  ╰─ · proxy  ClassVar[dict[weakref.ref[Any]',
    '              , weakref.ref[Proxy[Any]]]]',
    '               ↑ReversibleProxy = {}',
  }
)

-- 8c. evaluated decorations: alias keeps declared name + ≈ suffix; an
-- unannotated param (implicit Any) shows only the inferred type
eq_lines(
  "evaluated decorations",
  render.render({
    model.new({
      name = "mode",
      kind = "param",
      type = { display = "LoopMode", category = "generic" },
      evaluated = "Literal['auto', 'manual']",
      default = '"auto"',
    }),
    model.new({
      name = "count",
      kind = "param",
      type = { display = "Any", category = "builtin" },
      evaluated = "int",
      default = "3",
    }),
  }, opts({ style = styles.get("rounded"), show_examples = false })).lines,
  {
    '· mode   LoopMode ≈ Literal[\'auto\', \'manual\'] = "auto"',
    '· count  ≈ int = 3',
  }
)

-- 8. inherited fields render with the origin tag
eq_lines(
  "origin tag on inherited fields",
  render.render({
    model.new({
      name = "cfg",
      kind = "param",
      expanded = true,
      type = { display = "Child", category = "dataclass" },
      children = {
        { name = "z", type = { display = "float", category = "builtin" } },
        { name = "x", type = { display = "int", category = "builtin" }, origin = "Base" },
      },
    }),
  }, opts({ show_examples = false })).lines,
  {
    '▾ cfg  Child',
    '  ├─ · z  float',
    '  └─ · x  int ↑Base',
  }
)

-- 9. unified-float sections: header + separators + docstring (U1)
local section_tree = { model.new({ name = "x", kind = "param", type = { display = "int", category = "builtin" } }) }
eq_lines(
  "sections: header + collapsed docstring at bottom",
  render.render(section_tree, opts({
    style = styles.get("rounded"),
    max_width = 40,
    show_examples = false,
    header = "f(x, *, y=…) -> str",
    docstring = "First line of prose.\n\nSecond paragraph here.",
    docstring_expanded = false,
    docstring_pos = "bottom",
  })).lines,
  {
    'f(x, *, y=…) -> str',
    '────────────────────',
    '· x  int',
    '────────────────────',
    'First line of prose.',
  }
)
eq_lines(
  "sections: expanded docstring at top",
  render.render(section_tree, opts({
    style = styles.get("rounded"),
    max_width = 40,
    show_examples = false,
    header = "f(x) -> str",
    docstring = "First line of prose.\n\nSecond paragraph here.",
    docstring_expanded = true,
    docstring_pos = "top",
  })).lines,
  {
    'f(x) -> str',
    'First line of prose.',
    '',
    'Second paragraph here.',
    '──────────────────────',
    '· x  int',
  }
)

-- the docstring section's line range rides the result so interact can give
-- it plain-movement semantics and jump `d` presses into it
do
  local bottom = render.render(section_tree, opts({
    style = styles.get("rounded"),
    max_width = 40,
    show_examples = false,
    header = "f(x, *, y=…) -> str",
    docstring = "First line of prose.\n\nSecond paragraph here.",
    docstring_expanded = false,
    docstring_pos = "bottom",
  }))
  check("doc range: collapsed bottom section is the last line", bottom.doc_start == 5 and bottom.doc_end == 5)
  local top = render.render(section_tree, opts({
    style = styles.get("rounded"),
    max_width = 40,
    show_examples = false,
    header = "f(x) -> str",
    docstring = "First line of prose.\n\nSecond paragraph here.",
    docstring_expanded = true,
    docstring_pos = "top",
  }))
  check("doc range: expanded top section spans lines 2-4", top.doc_start == 2 and top.doc_end == 4)
  local none = render.render(section_tree, opts({ show_examples = false }))
  check("doc range: absent without a docstring", none.doc_start == nil and none.doc_end == nil)
end

-- 10. table layout (U5): column grid — name | */ | type | default | example |
-- origin — alternating row backgrounds, wrapped cells continue in-column
do
  local table_tree = {
    model.new({
      name = "config",
      kind = "param",
      expanded = true,
      type = { raw = "ServerConfig", display = "ServerConfig", category = "dataclass" },
      children = {
        { name = "host", kind = "field", type = { raw = "str", display = "str", category = "builtin" }, example = { heuristic = '"localhost"' } },
        { name = "port", kind = "field", type = { raw = "int", display = "int", category = "builtin" }, default = "8000" },
        { name = "env", kind = "field", type = { raw = "str", display = "str", category = "builtin" }, origin = "BaseConfig" },
      },
    }),
    model.new({
      name = "host",
      kind = "param",
      pass_mode = "*",
      type = { raw = "str", display = "str", category = "builtin" },
      default = '"127.0.0.1"',
    }),
    model.new({
      name = "lifespan",
      kind = "param",
      pass_mode = "*",
      type = { raw = "LifespanType", display = "LifespanType", category = "generic" },
      evaluated = 'Literal["auto", "on", "off"]',
      default = '"auto"',
    }),
    model.new({ name = "returns", kind = "return", type = { raw = "None", display = "None", category = "builtin" } }),
  }
  local tr = render.render(table_tree, opts({
    style = styles.get("rounded"),
    max_width = 78,
    layout = "table",
    show_examples = true,
  }))
  eq_lines("table layout golden", tr.lines, {
    "▾ config        ServerConfig                                                  ",
    "  ├─ · host     str                                   \"localhost\"             ",
    "  ├─ · port     int                    = 8000                                 ",
    "  ╰─ · env      str                                                ↑BaseConfig",
    "· host       *  str                    = \"127.0.0.1\"                          ",
    "· lifespan   *  LifespanType ≈         = \"auto\"                               ",
    "                Literal[\"auto\", \"on\",                                         ",
    "                \"off\"]                                                        ",
    "· returns       None                                                          ",
  })
  -- alternating rows: odd NODE rows (1st, 3rd, 5th...) carry the bg group at
  -- sub-100 priority; a wrapped row's continuations share its parity
  local alt_lines = {}
  for _, h in ipairs(tr.highlights) do
    if h.group == "TypeScopeRowOdd" then
      alt_lines[h.line] = h.priority
    end
  end
  check(
    "alternating rows on odd node rows, priority under text",
    alt_lines[0] == 90 and alt_lines[2] == 90 and alt_lines[4] == 90 and alt_lines[8] == 90
      and alt_lines[1] == nil and alt_lines[5] == nil and alt_lines[6] == nil
  )
  -- injections: unsplit default cell keeps replace; wrapped type cell drops
  local inj = {}
  for _, ij in ipairs(tr.ts_injections) do
    inj[ij.text] = ij.mode
  end
  check("table injections: unsplit cells only", inj["8000"] == "replace" and inj["LifespanType"] == nil)
  -- every line of a row maps back to its node
  check(
    "table line_to_node covers continuations",
    tr.line_to_node[7] == "lifespan" and tr.line_to_node[8] == "lifespan" and tr.line_to_node[2] == "config.host"
  )
end

-- 11. ledger layout (U6): one line per node — name | type | short default —
-- with a detail block (≈ owner, full default, example, origin) on detail_id
do
  local function ledger_tree()
    local t = {
      model.new({
        name = "config",
        kind = "param",
        expanded = true,
        type = { raw = "ServerConfig", display = "ServerConfig", category = "dataclass" },
        children = {
          { name = "host", kind = "field", type = { raw = "str", display = "str", category = "builtin" }, example = { heuristic = '"localhost"' } },
          { name = "port", kind = "field", type = { raw = "int", display = "int", category = "builtin" }, default = "8000" },
          { name = "env", kind = "field", type = { raw = "str", display = "str", category = "builtin" }, origin = "BaseConfig" },
        },
      }),
      model.new({
        name = "host",
        kind = "param",
        pass_mode = "*",
        type = { raw = "str", display = "str", category = "builtin" },
        default = '"127.0.0.1"',
      }),
      model.new({
        name = "ws",
        kind = "param",
        pass_mode = "*",
        type = { raw = "type[Protocol] | WSProtocolType", display = "type[Protocol] | WSProtocolType", category = "generic" },
        evaluated = 'Literal["auto", "none"]',
        default = '"auto"',
        example = { heuristic = '"none"' },
      }),
      model.new({ name = "returns", kind = "return", type = { raw = "None", display = "None", category = "builtin" } }),
    }
    t[3].evaluated_owner = "WSProtocolType"
    return t
  end
  local lopts = opts({ style = styles.get("rounded"), max_width = 60, layout = "ledger" })
  local lr = render.render(ledger_tree(), lopts)
  eq_lines("ledger layout golden (no detail)", lr.lines, {
    '▾   config     ServerConfig',
    '  ├─ ·   host  str',
    '  ├─ ·   port  int  = 8000',
    '  ╰─ ·   env   str',
    '· * host       str  = "127.0.0.1"',
    '· * ws         type[Protocol] | WSProtocolType  = "auto"',
    '·   returns    None',
  })
  -- rows carry no examples, no origins, no ≈, no expand hints — detail's job
  local all = table.concat(lr.lines, "\n")
  check(
    "ledger rows stay lean",
    not all:find("localhost") and not all:find("BaseConfig") and not all:find("≈") and not all:find("<CR>")
  )

  -- detail on ws: inline default moves into the block; the ≈ line names the
  -- union member that answered (evaluated_owner), not the whole annotation
  local dr = render.render(ledger_tree(), opts({ style = styles.get("rounded"), max_width = 60, layout = "ledger", detail_id = "ws" }))
  eq_lines("ledger detail block golden", dr.lines, {
    '▾   config     ServerConfig',
    '  ├─ ·   host  str',
    '  ├─ ·   port  int  = 8000',
    '  ╰─ ·   env   str',
    '· * host       str  = "127.0.0.1"',
    '· * ws         type[Protocol] | WSProtocolType',
    '  │ ≈ WSProtocolType = Literal["auto", "none"]',
    '  │ = "auto"   e.g. "none"',
    '·   returns    None',
  })
  check("ledger detail lines map to their owner", dr.line_to_node[7] == "ws" and dr.line_to_node[8] == "ws" and dr.line_to_node[9] == "returns")

  -- detail on an inherited field shows its origin
  local er = render.render(ledger_tree(), opts({ style = styles.get("rounded"), max_width = 60, layout = "ledger", detail_id = "config.env" }))
  check("ledger detail shows origin", table.concat(er.lines, "\n"):find("↑BaseConfig") ~= nil)

  -- long identifiers middle-ellipsize at the 24-cell cap
  local long = render.render(
    { model.new({ name = "ws_per_message_deflate_enabled", kind = "param", type = { display = "bool", category = "builtin" } }) },
    lopts
  )
  check("ledger caps long names with middle ellipsis", long.lines[1]:find("…") ~= nil and long.lines[1]:find("bool") ~= nil)
end

-- 12. insert ladder (U6): one line, fixed degradation order
do
  local node = model.new({
    name = "port",
    kind = "param",
    type = { raw = "int", display = "int", category = "builtin" },
    default = "8000",
    example = { heuristic = "8080" },
  })
  -- fn/badge/ret render only in the signature block; without params the
  -- ladder is the bare detail
  local base = { show_examples = true, example_kind = "heuristic", fn_name = "run", badge = "[2/2]" }
  local full = render.ladder(node, vim.tbl_extend("force", base, { max_width = 60 }))
  eq_lines("ladder full", full.lines, { "port: int = 8000   e.g. 8080" })
  check("ladder maps to the param", full.line_to_node[1] == "port")
  -- out of room → the detail WRAPS (hanging indent); nothing is dropped
  local wrapped = render.ladder(node, vim.tbl_extend("force", base, { max_width = 20 }))
  eq_lines("ladder wraps instead of dropping", wrapped.lines, {
    "port: int = 8000",
    "         e.g. 8080",
  })
  check("wrapped lines all map to the param", wrapped.line_to_node[1] == "port" and wrapped.line_to_node[2] == "port")

  -- a param with a limited set of valid values presents them (≈ evaluation),
  -- eliding member-by-member with a hidden-count before dropping entirely
  local mode = model.new({
    name = "mode",
    kind = "param",
    type = { display = "OpenTextMode", category = "generic" },
    evaluated = "Literal['r', 'w', 'x', 'a']",
    default = '"r"',
  })
  local vbase = { show_examples = true, example_kind = "heuristic", style = styles.get("unicode"), fn_name = "open", badge = "[1/7]" }
  local vfull = render.ladder(mode, vim.tbl_extend("force", vbase, { max_width = 80 }))
  eq_lines("ladder presents valid values", vfull.lines, { "mode: OpenTextMode ≈ Literal['r', 'w', 'x', 'a'] = \"r\"" })
  -- a modest overflow wraps with the FULL value set intact
  local vwrapped = render.ladder(mode, vim.tbl_extend("force", vbase, { max_width = 40 }))
  eq_lines("ladder wraps full valid values", vwrapped.lines, {
    "mode: OpenTextMode ≈ Literal['r', 'w',",
    "      'x', 'a'] = \"r\"",
  })
  -- only past the line cap does the shape elide member-by-member
  local members = {}
  for i = 1, 20 do
    members[i] = ("'m%02d'"):format(i)
  end
  local big = model.new({
    name = "mode",
    kind = "param",
    type = { display = "OpenTextMode", category = "generic" },
    evaluated = "Literal[" .. table.concat(members, ", ") .. "]",
    default = '"r"',
  })
  local capped = render.ladder(big, vim.tbl_extend("force", vbase, { max_width = 40 }))
  local call = table.concat(capped.lines, "\n")
  check(
    "ladder caps wrapped lines, then elides the shape",
    #capped.lines <= 3 and call:find("…%+") ~= nil and not call:find("'m20'")
  )

  -- a resolved class param presents its field shape the same way
  local struct = model.new({
    name = "config",
    kind = "param",
    type = { display = "ServerConfig", category = "dataclass" },
    children = {
      { name = "host", type = { display = "str", category = "builtin" } },
      { name = "port", type = { display = "int", category = "builtin" } },
      { name = "env", type = { display = "str", category = "builtin" } },
    },
  })
  local sfull = render.ladder(struct, { show_examples = false, example_kind = "heuristic", max_width = 60 })
  eq_lines("ladder presents a class param's shape", sfull.lines, { "config: ServerConfig ≈ {host, port, env}" })

  -- signature block: K-consistent header — name(params) -> ret [i/m] — with
  -- the active param lit, above a rule
  local pfull = render.ladder(
    node,
    vim.tbl_extend("force", base, {
      max_width = 60,
      ret = "None",
      params = { { name = "app", active = false }, { name = "host", active = false }, { name = "port", active = true } },
    })
  )
  eq_lines("ladder signature block + rule + detail", pfull.lines, {
    "run(app, host, port) -> None [2/2]",
    string.rep("─", 34),
    "port: int = 8000   e.g. 8080",
  })
  check("signature lines carry no node mapping; detail does", pfull.line_to_node[1] == nil and pfull.line_to_node[3] == "port")
  local wrap_params = {}
  for _, n in ipairs({ "app", "host", "port", "ws_max_size", "lifespan", "reload" }) do
    table.insert(wrap_params, { name = n, active = n == "port" })
  end
  local pwrap = render.ladder(node, vim.tbl_extend("force", base, { max_width = 24, params = wrap_params }))
  local wall = table.concat(pwrap.lines, "\n")
  check(
    "signature block wraps so every name stays visible",
    #pwrap.lines > 3 and wall:find("ws_max_size") ~= nil and wall:find("lifespan") ~= nil and wall:find("reload") ~= nil
  )
end

-- 38c: pending examples render in their own group so one timer can breathe
-- them. Render stays pure — it never asks the examples module anything, it
-- consults the predicate handed to it through opts.
do
  ---@param llm string? the LLM value, if it has landed
  local function groups_for(over, llm)
    local node = model.new({ name = "host", kind = "param", type = { display = "str", category = "builtin" } })
    -- the heuristic always stands underneath: that's what a pending row shows
    -- while it waits, and what a MISS leaves behind
    node.example.heuristic = '"localhost"'
    node.example.llm = llm
    local r = render.render({ node }, opts(over))
    local found = {}
    for _, h in ipairs(r.highlights) do
      found[h.group] = true
    end
    found.injected = false
    for _, ij in ipairs(r.ts_injections) do
      if ij.text == (llm or '"localhost"') then
        found.injected = true
      end
    end
    return found
  end

  local pending = function()
    return true
  end
  local function any_pending_group(found)
    for name in pairs(found) do
      if type(name) == "string" and name:find("^TypeScopeExamplePending") then
        return true
      end
    end
    return false
  end
  check(
    "llm mode: a still-coming example takes a pending group",
    any_pending_group(groups_for({ example_kind = "llm", example_pending = pending }))
  )
  check(
    "llm mode: a landed example takes the normal group",
    groups_for({ example_kind = "llm", example_pending = function()
      return false
    end }, '"example.com"')["TypeScopeExample"] == true
  )
  -- a heuristic value is final the moment it exists: nothing to wait for, so
  -- nothing to breathe even if a stale predicate says otherwise
  check(
    "heuristic mode never renders pending",
    groups_for({ example_pending = pending })["TypeScopeExamplePending"] == nil
  )
  check("no predicate (spike, tests) renders normally", groups_for({ example_kind = "llm" })["TypeScopeExample"] == true)

  -- a leaf no heuristic matches has no example line at all; while its value
  -- is coming, a bar holds the line open so the block doesn't grow one later
  do
    local bare = model.new({ name = "object", kind = "param", type = { display = "_T", category = "typevar" } })
    local waiting = render.render({ bare }, opts({ example_kind = "llm", example_pending = pending }))
    local settled = render.render({ bare }, opts({ example_kind = "llm" }))
    -- one full wavelength, so every rung of the ladder is on screen at once
    check(
      "pending leaf with no heuristic shows the wave bar",
      waiting.lines[1]:find("▁") and waiting.lines[1]:find("▇") and waiting.lines[1]:find("▅")
    )
    local ascii = render.render({ bare }, opts({
      style = styles.get("ascii"),
      example_kind = "llm",
      example_pending = pending,
    })).lines[1]
    check("bar uses the charset ladder", ascii:find("%.") and ascii:find("#") and not ascii:find("▇"))
    check("nothing pending, nothing shown", settled.lines[1]:find("▇") == nil)
    -- the type annotation always injects; the bar must not — it isn't code
    local bar_injected = false
    for _, ij in ipairs(waiting.ts_injections) do
      if ij.text:find("▇") then
        bar_injected = true
      end
    end
    check("the bar is not syntax-highlighted as a value", not bar_injected)
  end

  -- 38c: the reveal wave. A landed value sweeps left to right — lit prefix in
  -- real syntax colors, bar over the rest — at a constant cell count, so the
  -- line never reflows mid-animation.
  do
    local value = '{"name": "John Doe"}'
    local node = model.new({ name = "object", kind = "param", type = { display = "_T", category = "typevar" } })
    node.example.llm = value
    local progress
    local function frame(over)
      return render.render({ node }, opts(vim.tbl_extend("force", {
        example_kind = "llm",
        example_pending = function()
          return false
        end,
        -- pin the frozen phase: which cells uncover first is a function of
        -- where the wave stood, so an unpinned phase makes this test drift
        example_reveal = function()
          return progress, 0.3
        end,
      }, over or {})))
    end

    progress = 0
    local start = frame()
    -- the wave freezes where it stood: it does NOT snap to a full-height bar
    check("the fall starts from the frozen wave", rung_count(start.lines[1]) >= 3)
    check("no value text visible yet", not start.lines[1]:find("John"))

    progress = 0.75
    local mid = frame()
    check("mid-fall uncovers some of the value", mid.lines[1]:find('name', 1, true) ~= nil)
    check("mid-fall still has blocks standing", mid.lines[1]:find("[▁▂▃▅▇]") ~= nil)
    check("mid-fall has not uncovered all of it", not mid.lines[1]:find(value, 1, true))

    progress = nil
    local done = frame()
    check("settled shows the whole value", done.lines[1]:find(value, 1, true) ~= nil)
    -- the bar holds a space wider than most values, so the reveal only ever
    -- narrows the row — the value is uncovered inside room already reserved,
    -- never shoved into place
    local w_start = vim.api.nvim_strwidth(start.lines[1])
    local w_mid = vim.api.nvim_strwidth(mid.lines[1])
    local w_done = vim.api.nvim_strwidth(done.lines[1])
    check("the reveal never widens the row", w_start >= w_mid and w_mid >= w_done)
    check("the bar reserves more room than this value needs", w_start > w_done)
    -- uncovered runs are real code again, blocks never are
    local lit_injected, bar_injected = false, false
    for _, ij in ipairs(mid.ts_injections) do
      if ij.text:find("name", 1, true) then
        lit_injected = true
      end
      if ij.text:find("[▁▂▃▅▇]") then
        bar_injected = true
      end
    end
    check("uncovered runs get syntax colors back", lit_injected)
    check("blocks never do", not bar_injected)

    -- a MISS has nothing underneath, so the bar drains off the line instead of
    -- disappearing between two frames
    local missed = model.new({ name = "kwargs", kind = "param", type = { display = "T", category = "builtin" } })
    local function miss_frame(pr)
      return render.render({ missed }, opts({
        example_kind = "llm",
        example_pending = function()
          return false
        end,
        example_reveal = function()
          return pr, 0.3
        end,
      })).lines[1]
    end
    check("a MISS still falls away rather than popping", miss_frame(0.1):find("[▁▂▃▅▇]") ~= nil)
    check("...and leaves nothing behind", not miss_frame(nil):find("[▁▂▃▅▇]"))

    -- a pending node has no value yet, so a stale reveal must not fire
    progress = 0.5
    local bare = model.new({ name = "x", kind = "param", type = { display = "_T", category = "typevar" } })
    local waiting = render.render({ bare }, opts({
      example_kind = "llm",
      example_pending = function()
        return true
      end,
      example_reveal = function()
        return progress
      end,
    }))
    check(
      "pending beats reveal: the placeholder stays whole",
      rung_count(waiting.lines[1]) >= 3 and not waiting.lines[1]:find("John")
    )
  end

  -- syntax colors are painted OVER the base extmark, so an overlaid example
  -- can't show the group breathing underneath: pending examples drop the
  -- injection and go flat until their value lands
  check(
    "pending example drops the syntax overlay",
    groups_for({ example_kind = "llm", example_pending = pending }).injected == false
  )
  check(
    "landed example keeps it",
    groups_for({ example_kind = "llm", example_pending = function()
      return false
    end }, '"example.com"').injected == true
  )
end

-- d1x: L's transient peek opens every ledger detail block at once. Without it
-- only the cursor's row carries one, so an expanded tree still shows exactly
-- one example — which made 38c's animation impossible to watch across rows.
do
  local roots = {
    model.new({ name = "host", kind = "param", type = { display = "str", category = "builtin" } }),
    model.new({ name = "port", kind = "param", type = { display = "int", category = "builtin" } }),
    model.new({ name = "timeout", kind = "param", type = { display = "float", category = "builtin" } }),
  }
  require("typescope.examples").annotate(roots)
  local base = opts({ layout = "ledger" })
  local function example_lines(over)
    local n = 0
    for _, line in ipairs(render.render(roots, vim.tbl_extend("force", base, over)).lines) do
      if line:find("e%.g%.") then
        n = n + 1
      end
    end
    return n
  end
  check("cursor-follow ledger shows one example", example_lines({ detail_id = roots[1].id }) == 1)
  check("detail_all opens every one", example_lines({ detail_all = true }) == 3)
  check("no detail, no examples", example_lines({}) == 0)
end

print(failures == 0 and "RENDER ALL PASS" or ("RENDER " .. failures .. " FAILURES"))
