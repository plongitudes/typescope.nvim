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

-- Distinct ramp rungs present in a line. Plain find per rung, NOT a pattern
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

-- Every injection has to describe a slice that actually FITS the line it sits
-- on. float.inject_highlights parses the whole snippet and places the spans
-- covering inj.from..inj.to at inj.col_start; if that reaches past the end of
-- the line, nvim_buf_set_extmark raises "Invalid 'col': out of range" and the
-- float never paints.
--
-- Asserted as a blanket invariant over any render result rather than as a
-- golden for one case, because the way this got shipped was a wrapping typing surface
-- fixture that checked its lines and never looked at its injections
-- (render.typing_surface's push dropped from/to where render()'s emit kept them).
---@param desc string
---@param result typescope.RenderResult
local function check_injections(desc, result)
  local bad = nil
  for _, inj in ipairs(result.ts_injections or {}) do
    local from, to = inj.from or 0, inj.to or #inj.text
    local line = result.lines[inj.line + 1] or ""
    if to < from or to > #inj.text then
      bad = bad or ("slice %d..%d outside a %d-byte snippet"):format(from, to, #inj.text)
    elseif inj.col_start + (to - from) > #line then
      bad = bad
        or ("line %d: col %d + %d bytes overruns a %d-byte line"):format(inj.line, inj.col_start, to - from, #line)
    end
  end
  check(desc .. " keeps every injection inside its line", bad == nil)
  if bad then
    print("  " .. bad)
  end
end

-- Nothing the renderer emits may be invalid UTF-8. Every truncation in this
-- file is handed a budget in DISPLAY CELLS and returns a byte slice, and for a
-- long time several of them indexed bytes with the cell count directly — which
-- splits a character and puts a literal <c3> on screen.
--
-- Checked as a blanket invariant rather than per site: the fixtures were all
-- ASCII, so every golden test passed while three separate truncations were
-- broken. vim.str_utfindex does not validate, so this decodes.
---@param s string
local function valid_utf8(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    local len
    if c < 0x80 then
      len = 1
    elseif c >= 0xC2 and c <= 0xDF then
      len = 2
    elseif c >= 0xE0 and c <= 0xEF then
      len = 3
    elseif c >= 0xF0 and c <= 0xF4 then
      len = 4
    else
      return false
    end
    if i + len - 1 > n then
      return false
    end
    for k = 1, len - 1 do
      local b = s:byte(i + k)
      if b < 0x80 or b > 0xBF then
        return false
      end
    end
    i = i + len
  end
  return true
end

---@param desc string
---@param result typescope.RenderResult
local function check_utf8(desc, result)
  local bad = nil
  for i, line in ipairs(result.lines) do
    if not valid_utf8(line) then
      bad = bad or ("line %d: %s"):format(i, vim.inspect(line))
    end
  end
  check(desc .. " emits only valid UTF-8", bad == nil)
  if bad then
    print("  " .. bad)
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
  "▾ config   ServerConfig",
  '  ├─ · host        str  "localhost"',
  "  ├─ ▾ retry       RetryPolicy",
  "  │ └─ · max_attempts  int = 3",
  "  └─ · timeout_ms  int | None NotRequired = None",
  "· opaque   Mystery [?]",
  "▸ returns  Response  (<CR> to expand)",
})

-- 2. right-aligned rounded, examples off
eq_lines(
  "right/rounded",
  render.render(tree(), opts({ style = styles.get("rounded"), align = "right", show_examples = false })).lines,
  {
    " ▾ config  ServerConfig",
    "  ├─       · host  str",
    "  ├─      ▾ retry  RetryPolicy",
    "  │ ╰─ · max_attempts  int = 3",
    "  ╰─ · timeout_ms  int | None NotRequired = None",
    " · opaque  Mystery [?]",
    "▸ returns  Response  (<CR> to expand)",
  }
)

-- 3. wrap at 40: hanging indent, tree bars carried onto continuations
eq_lines(
  "wrap-40 hanging indent",
  render.render(tree(), opts({ style = styles.get("rounded"), max_width = 40, show_examples = false })).lines,
  {
    "▾ config   ServerConfig",
    "  ├─ · host        str",
    "  ├─ ▾ retry       RetryPolicy",
    "  │ ╰─ · max_attempts  int = 3",
    "  ╰─ · timeout_ms  int | None",
    "                    NotRequired = None",
    "· opaque   Mystery [?]",
    "▸ returns  Response  (<CR> to expand)",
  }
)

-- 4. minimal style: indentation only
eq_lines("minimal style", render.render(tree(), opts({ style = styles.get("minimal"), show_examples = false })).lines, {
  "- config   ServerConfig",
  "      host        str",
  "    - retry       RetryPolicy",
  "        max_attempts  int = 3",
  "      timeout_ms  int | None NotRequired = None",
  "  opaque   Mystery [?]",
  "+ returns  Response  (<CR> to expand)",
})

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
  kinds["ServerConfig"] == "replace" and kinds["3"] == "replace" and kinds['"localhost"'] == "overlay"
)
-- a split annotation still injects: each piece names the WHOLE annotation as
-- its snippet and the byte slice of it that landed on that line, so a
-- continuation reading `Awaitable[Response | None]]]` is painted from the
-- colors the full type parses to rather than dropping to the base group
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
local annotation = "dict[str, Callable[[Request, Session], Awaitable[Response | None]]]"
local pieces, default_injected, slices_sound = {}, false, true
for _, ij in ipairs(wide.ts_injections) do
  if ij.text == annotation then
    table.insert(pieces, ij)
    -- the slice has to name real bytes of the snippet, and the line has to
    -- actually hold them at col_start: an off-by-one here paints a wrapped
    -- type with its neighbour's colors, which is invisible until it isn't
    local slice = annotation:sub(ij.from + 1, ij.to)
    local line = wide.lines[ij.line + 1]
    if slice == "" or line:sub(ij.col_start + 1, ij.col_start + #slice) ~= slice then
      slices_sound = false
    end
  end
  if ij.text == "None" then
    default_injected = true
  end
end
table.sort(pieces, function(a, b)
  return a.from < b.from
end)
local covered = #pieces > 0 and pieces[1].from == 0 and pieces[#pieces].to == #annotation
for i = 2, #pieces do
  -- flow strips the blank after a break, so pieces may skip a byte but never
  -- overlap and never leave a gap wider than the whitespace it dropped
  local gap = annotation:sub(pieces[i - 1].to + 1, pieces[i].from)
  if not gap:match("^%s*$") then
    covered = false
  end
end
check("a split annotation injects as slices of the whole", #pieces > 1 and covered and slices_sound)
check("an unsplit default still injects", default_injected)

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
    "▾ px  Wrap",
    "  ╰─ · proxy  ClassVar[dict[weakref.ref[Any]",
    "              , weakref.ref[Proxy[Any]]]]",
    "               ↑ReversibleProxy = {}",
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
    "· mode   LoopMode ≈ Literal['auto', 'manual'] = \"auto\"",
    "· count  ≈ int = 3",
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
    "▾ cfg  Child",
    "  ├─ · z  float",
    "  └─ · x  int ↑Base",
  }
)

-- 9. unified-float sections: header + separators + docstring (U1)
local section_tree = { model.new({ name = "x", kind = "param", type = { display = "int", category = "builtin" } }) }
eq_lines(
  "sections: header + collapsed docstring at bottom",
  render.render(
    section_tree,
    opts({
      style = styles.get("rounded"),
      max_width = 40,
      show_examples = false,
      header = "f(x, *, y=…) -> str",
      docstring = "First line of prose.\n\nSecond paragraph here.",
      docstring_expanded = false,
      docstring_pos = "bottom",
    })
  ).lines,
  {
    "f(x, *, y=…) -> str",
    "────────────────────",
    "· x  int",
    "────────────────────",
    "First line of prose.",
  }
)
eq_lines(
  "sections: expanded docstring at top",
  render.render(
    section_tree,
    opts({
      style = styles.get("rounded"),
      max_width = 40,
      show_examples = false,
      header = "f(x) -> str",
      docstring = "First line of prose.\n\nSecond paragraph here.",
      docstring_expanded = true,
      docstring_pos = "top",
    })
  ).lines,
  {
    "f(x) -> str",
    "First line of prose.",
    "",
    "Second paragraph here.",
    "──────────────────────",
    "· x  int",
  }
)

-- the docstring section's line range rides the result so interact can give
-- it plain-movement semantics and jump `d` presses into it
do
  local bottom = render.render(
    section_tree,
    opts({
      style = styles.get("rounded"),
      max_width = 40,
      show_examples = false,
      header = "f(x, *, y=…) -> str",
      docstring = "First line of prose.\n\nSecond paragraph here.",
      docstring_expanded = false,
      docstring_pos = "bottom",
    })
  )
  check("doc range: collapsed bottom section is the last line", bottom.doc_start == 5 and bottom.doc_end == 5)
  local top = render.render(
    section_tree,
    opts({
      style = styles.get("rounded"),
      max_width = 40,
      show_examples = false,
      header = "f(x) -> str",
      docstring = "First line of prose.\n\nSecond paragraph here.",
      docstring_expanded = true,
      docstring_pos = "top",
    })
  )
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
        {
          name = "host",
          kind = "field",
          type = { raw = "str", display = "str", category = "builtin" },
          example = { heuristic = '"localhost"' },
        },
        {
          name = "port",
          kind = "field",
          type = { raw = "int", display = "int", category = "builtin" },
          default = "8000",
        },
        {
          name = "env",
          kind = "field",
          type = { raw = "str", display = "str", category = "builtin" },
          origin = "BaseConfig",
        },
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
  local tr = render.render(
    table_tree,
    opts({
      style = styles.get("rounded"),
      max_width = 78,
      layout = "table",
      show_examples = true,
    })
  )
  eq_lines("table layout golden", tr.lines, {
    "▾ config        ServerConfig                                                  ",
    '  ├─ · host     str                                   "localhost"             ',
    "  ├─ · port     int                    = 8000                                 ",
    "  ╰─ · env      str                                                ↑BaseConfig",
    '· host       *  str                    = "127.0.0.1"                          ',
    '· lifespan   *  LifespanType ≈         = "auto"                               ',
    '                Literal["auto", "on",                                         ',
    '                "off"]                                                        ',
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
    alt_lines[0] == 90
      and alt_lines[2] == 90
      and alt_lines[4] == 90
      and alt_lines[8] == 90
      and alt_lines[1] == nil
      and alt_lines[5] == nil
      and alt_lines[6] == nil
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
          {
            name = "host",
            kind = "field",
            type = { raw = "str", display = "str", category = "builtin" },
            example = { heuristic = '"localhost"' },
          },
          {
            name = "port",
            kind = "field",
            type = { raw = "int", display = "int", category = "builtin" },
            default = "8000",
          },
          {
            name = "env",
            kind = "field",
            type = { raw = "str", display = "str", category = "builtin" },
            origin = "BaseConfig",
          },
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
        type = {
          raw = "type[Protocol] | WSProtocolType",
          display = "type[Protocol] | WSProtocolType",
          category = "generic",
        },
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
    "▾   config     ServerConfig",
    "  ├─ ·   host  str",
    "  ├─ ·   port  int  = 8000",
    "  ╰─ ·   env   str",
    '· * host       str  = "127.0.0.1"',
    '· * ws         type[Protocol] | WSProtocolType  = "auto"',
    "·   returns    None",
  })
  -- rows carry no examples, no origins, no ≈, no expand hints — detail's job
  local all = table.concat(lr.lines, "\n")
  check(
    "ledger rows stay lean",
    not all:find("localhost") and not all:find("BaseConfig") and not all:find("≈") and not all:find("<CR>")
  )

  -- detail on ws: inline default moves into the block; the ≈ line names the
  -- union member that answered (evaluated_owner), not the whole annotation
  local dr = render.render(
    ledger_tree(),
    opts({ style = styles.get("rounded"), max_width = 60, layout = "ledger", detail_id = "ws" })
  )
  eq_lines("ledger detail block golden", dr.lines, {
    "▾   config     ServerConfig",
    "  ├─ ·   host  str",
    "  ├─ ·   port  int  = 8000",
    "  ╰─ ·   env   str",
    '· * host       str  = "127.0.0.1"',
    "· * ws         type[Protocol] | WSProtocolType",
    '  │ ≈ WSProtocolType = Literal["auto", "none"]',
    '  │ = "auto"   e.g. "none"',
    "·   returns    None",
  })
  check(
    "ledger detail lines map to their owner",
    dr.line_to_node[7] == "ws" and dr.line_to_node[8] == "ws" and dr.line_to_node[9] == "returns"
  )

  -- detail on an inherited field shows its origin
  local er = render.render(
    ledger_tree(),
    opts({ style = styles.get("rounded"), max_width = 60, layout = "ledger", detail_id = "config.env" })
  )
  check("ledger detail shows origin", table.concat(er.lines, "\n"):find("↑BaseConfig") ~= nil)

  -- long identifiers middle-ellipsize at the 24-cell cap
  local long = render.render({
    model.new({
      name = "ws_per_message_deflate_enabled",
      kind = "param",
      type = { display = "bool", category = "builtin" },
    }),
  }, lopts)
  check(
    "ledger caps long names with middle ellipsis",
    long.lines[1]:find("…") ~= nil and long.lines[1]:find("bool") ~= nil
  )
end

-- 12. insert typing surface (U6): one line, fixed degradation order
do
  local node = model.new({
    name = "port",
    kind = "param",
    type = { raw = "int", display = "int", category = "builtin" },
    default = "8000",
    example = { heuristic = "8080" },
  })
  -- fn/badge/ret render only in the signature block; without params the
  -- typing surface is the bare detail
  local base = { show_examples = true, example_kind = "heuristic", fn_name = "run", badge = "[2/2]" }
  local full = render.typing_surface(node, vim.tbl_extend("force", base, { max_width = 60 }))
  eq_lines("typing surface full", full.lines, { "port: int = 8000   e.g. 8080" })
  check("typing surface maps to the param", full.line_to_node[1] == "port")
  -- out of room → the detail WRAPS (hanging indent); nothing is dropped
  local wrapped = render.typing_surface(node, vim.tbl_extend("force", base, { max_width = 20 }))
  eq_lines("typing surface wraps instead of dropping", wrapped.lines, {
    "port: int = 8000",
    "         e.g. 8080",
  })
  check("wrapped lines all map to the param", wrapped.line_to_node[1] == "port" and wrapped.line_to_node[2] == "port")
  check_injections("typing surface full", full)
  check_injections("wrapped typing surface", wrapped)

  -- the real crash shape: an annotation long enough that the TYPE ITSELF is
  -- split across lines, so each line carries a different slice of one snippet.
  -- With from/to dropped, every one of these claimed the whole 67-byte
  -- annotation and the second line's extmark ran 48 bytes past its end.
  local wide = model.new({
    name = "handlers",
    kind = "param",
    type = {
      raw = "dict[str, Callable[[Request, Session], Awaitable[Response | None]]]",
      display = "dict[str, Callable[[Request, Session], Awaitable[Response | None]]]",
      category = "generic",
    },
  })
  local split = render.typing_surface(wide, { show_examples = false, example_kind = "heuristic", max_width = 30 })
  check("a long annotation splits across lines", #split.lines > 2)
  check_injections("split-annotation typing surface", split)
  -- the slices walk the snippet forward without overlapping, and between them
  -- reach its end. NOT contiguous: a wrap strips the leading space from the
  -- remainder and steps `from` over it, so each break leaves a gap the width
  -- of the whitespace that was dropped.
  -- defaulted the same way float.inject_highlights defaults them, so a
  -- regression that drops the fields fails this check instead of erroring on
  -- a nil comparison and taking the rest of the suite with it
  local walked, ordered = 0, true
  for _, inj in ipairs(split.ts_injections) do
    local from, to = inj.from or 0, inj.to or #inj.text
    ordered = ordered and from >= walked
    walked = to
  end
  check("...its slices walk the annotation in order, to the end", ordered and walked == #wide.type.display)

  -- a param with a limited set of valid values presents them (≈ evaluation),
  -- eliding member-by-member with a hidden-count before dropping entirely
  local mode = model.new({
    name = "mode",
    kind = "param",
    type = { display = "OpenTextMode", category = "generic" },
    evaluated = "Literal['r', 'w', 'x', 'a']",
    default = '"r"',
  })
  local vbase = {
    show_examples = true,
    example_kind = "heuristic",
    style = styles.get("unicode"),
    fn_name = "open",
    badge = "[1/7]",
  }
  local vfull = render.typing_surface(mode, vim.tbl_extend("force", vbase, { max_width = 80 }))
  eq_lines(
    "typing surface presents valid values",
    vfull.lines,
    { "mode: OpenTextMode ≈ Literal['r', 'w', 'x', 'a'] = \"r\"" }
  )
  -- a modest overflow wraps with the FULL value set intact
  local vwrapped = render.typing_surface(mode, vim.tbl_extend("force", vbase, { max_width = 40 }))
  eq_lines("typing surface wraps full valid values", vwrapped.lines, {
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
  local capped = render.typing_surface(big, vim.tbl_extend("force", vbase, { max_width = 40 }))
  local call = table.concat(capped.lines, "\n")
  check(
    "typing surface caps wrapped lines, then elides the shape",
    #capped.lines <= 3 and call:find("…%+") ~= nil and not call:find("'m20'")
  )

  -- max_detail_lines (10f) moves that cap. The same node at the same width
  -- gets more lines AND keeps more members, because the elision budget is
  -- computed from the cap: capacity = max_lines * width - indent * (max_lines-1).
  -- Asserting both halves matters — a cap that only changed the line count
  -- while still eliding to three lines' worth of members would be a knob that
  -- does half its job.
  local roomy = render.typing_surface(big, vim.tbl_extend("force", vbase, { max_width = 40, max_detail_lines = 6 }))
  local roomy_call = table.concat(roomy.lines, "\n")
  check("max_detail_lines raises the line cap", #roomy.lines > #capped.lines and #roomy.lines <= 6)
  check("a raised cap keeps more members", #roomy_call > #call)

  -- and downward: 1 line leaves no room to wrap into, so the shape goes
  -- entirely rather than the detail spilling past the cap
  local tight = render.typing_surface(big, vim.tbl_extend("force", vbase, { max_width = 40, max_detail_lines = 1 }))
  check("max_detail_lines lowers the cap too", #tight.lines <= 1)
  check("a cap of 1 drops the shape rather than overflowing", not table.concat(tight.lines, "\n"):find("'m01'"))

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
  local sfull = render.typing_surface(struct, { show_examples = false, example_kind = "heuristic", max_width = 60 })
  eq_lines(
    "typing surface presents a class param's shape",
    sfull.lines,
    { "config: ServerConfig ≈ {host, port, env}" }
  )

  -- signature block: K-consistent header — name(params) -> ret [i/m] — with
  -- the active param lit, above a rule
  local pfull = render.typing_surface(
    node,
    vim.tbl_extend("force", base, {
      max_width = 60,
      ret = "None",
      params = { { name = "app", active = false }, { name = "host", active = false }, { name = "port", active = true } },
    })
  )
  eq_lines("typing surface signature block + rule + detail", pfull.lines, {
    "run(app, host, port) -> None [2/2]",
    string.rep("─", 34),
    "port: int = 8000   e.g. 8080",
  })
  check(
    "signature lines carry no node mapping; detail does",
    pfull.line_to_node[1] == nil and pfull.line_to_node[3] == "port"
  )
  local wrap_params = {}
  for _, n in ipairs({ "app", "host", "port", "ws_max_size", "lifespan", "reload" }) do
    table.insert(wrap_params, { name = n, active = n == "port" })
  end
  local pwrap = render.typing_surface(node, vim.tbl_extend("force", base, { max_width = 24, params = wrap_params }))
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
  check("llm mode: a landed example takes the normal group", groups_for({
    example_kind = "llm",
    example_pending = function()
      return false
    end,
  }, '"example.com"')["TypeScopeExample"] == true)
  -- a heuristic value is final the moment it exists: nothing to wait for, so
  -- nothing to breathe even if a stale predicate says otherwise
  check(
    "heuristic mode never renders pending",
    groups_for({ example_pending = pending })["TypeScopeExamplePending"] == nil
  )
  check(
    "no predicate (spike, tests) renders normally",
    groups_for({ example_kind = "llm" })["TypeScopeExample"] == true
  )

  -- a leaf no heuristic matches has no example line at all; while its value
  -- is coming, a bar holds the line open so the block doesn't grow one later
  do
    local bare = model.new({ name = "object", kind = "param", type = { display = "_T", category = "typevar" } })
    local waiting = render.render({ bare }, opts({ example_kind = "llm", example_pending = pending }))
    local settled = render.render({ bare }, opts({ example_kind = "llm" }))
    -- one full wavelength, so every rung of the ramp is on screen at once
    check(
      "pending leaf with no heuristic shows the wave bar",
      waiting.lines[1]:find("▁") and waiting.lines[1]:find("▇") and waiting.lines[1]:find("▅")
    )
    local ascii = render.render(
      { bare },
      opts({
        style = styles.get("ascii"),
        example_kind = "llm",
        example_pending = pending,
      })
    ).lines[1]
    check("bar uses the charset ramp", ascii:find("%.") and ascii:find("#") and not ascii:find("▇"))
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
      return render.render(
        { node },
        opts(vim.tbl_extend("force", {
          example_kind = "llm",
          example_pending = function()
            return false
          end,
          -- pin the frozen phase: which cells uncover first is a function of
          -- where the wave stood, so an unpinned phase makes this test drift
          example_reveal = function()
            return progress, 0.3
          end,
        }, over or {}))
      )
    end

    progress = 0
    local start = frame()
    -- the wave freezes where it stood: it does NOT snap to a full-height bar
    check("the fall starts from the frozen wave", rung_count(start.lines[1]) >= 3)
    check("no value text visible yet", not start.lines[1]:find("John"))

    progress = 0.75
    local mid = frame()
    check("mid-fall uncovers some of the value", mid.lines[1]:find("name", 1, true) ~= nil)
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
      return render.render(
        { missed },
        opts({
          example_kind = "llm",
          example_pending = function()
            return false
          end,
          example_reveal = function()
            return pr, 0.3
          end,
        })
      ).lines[1]
    end
    check("a MISS still falls away rather than popping", miss_frame(0.1):find("[▁▂▃▅▇]") ~= nil)
    check("...and leaves nothing behind", not miss_frame(nil):find("[▁▂▃▅▇]"))

    -- The frozen wave is frozen in X too. Cells that drain with nothing under
    -- them hold their column with a space; emitting nothing instead pulled
    -- every block to their right one cell left per drained cell, so a MISS —
    -- which drains ALL of them — crept steadily leftwards the whole way down
    -- and read as the wave travelling again. Track the leftmost crest: it may
    -- shrink and vanish, but while it stands it must not move.
    -- Track the wave's PEAK, not a fixed brightness: every cell loses height
    -- together, so the tallest cell stays the tallest one — and stays put.
    -- Testing a fixed rung instead would fail honestly, since the whole wave
    -- sinks past any threshold you pick.
    local BAR = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
    local function peak_col(line)
      -- every glyph on this row is single-width, so index IS column
      local at = vim.str_utf_pos(line)
      local best, best_col = 0, nil
      for i = 1, #at do
        local ch = line:sub(at[i], (at[i + 1] or #line + 1) - 1)
        for rung, glyph in ipairs(BAR) do
          if ch == glyph and rung > best then
            best, best_col = rung, i
          end
        end
      end
      return best_col
    end
    local anchor = peak_col(miss_frame(0))
    check("a draining MISS has a peak to track", anchor ~= nil)
    local drifted = false
    for _, pr in ipairs({ 0.1, 0.2, 0.3, 0.4, 0.5 }) do
      local col = peak_col(miss_frame(pr))
      if col and col ~= anchor then
        drifted = true
      end
    end
    check("the frozen wave holds its columns as it drains", not drifted)

    -- a pending node has no value yet, so a stale reveal must not fire
    progress = 0.5
    local bare = model.new({ name = "x", kind = "param", type = { display = "_T", category = "typevar" } })
    local waiting = render.render(
      { bare },
      opts({
        example_kind = "llm",
        example_pending = function()
          return true
        end,
        example_reveal = function()
          return progress
        end,
      })
    )
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
  check("landed example keeps it", groups_for({
    example_kind = "llm",
    example_pending = function()
      return false
    end,
  }, '"example.com"').injected == true)
end

-- The bar's left edge has to read as the value's left edge, and the taper is
-- what blurred it: the value lands in column one, but the outer columns were
-- so faint that the bar looked like it began several columns in (Tony,
-- reveal.mov). The taper stays — it is what keeps the wave from being chopped
-- off mid-crest — but its SHAPE is now a quarter sine rather than a raised
-- cosine, steepest at the edge and easing only into the plateau.
--
-- What is asserted is that shape, not a column number: alpha is a tuning knob
-- (Tony has moved it twice), and a test that pins where the taper ends just
-- has to be rewritten every time it moves. A test that says the climb is
-- front-loaded holds at any width.
do
  local bare = model.new({ name = "x", kind = "param", type = { display = "_T", category = "typevar" } })
  -- the bar is the whole tail of the row, trailing height-0 cells included,
  -- so its columns are the last PENDING_CELLS characters of the line
  local WIDTH = 28
  local function bar_at(phase)
    local line = render.render(
      { bare },
      opts({
        example_kind = "llm",
        example_pending = function()
          return true
        end,
        example_phase = phase,
      })
    ).lines[1]
    local chars = vim.fn.strchars(line)
    local cells = {}
    for i = 1, WIDTH do
      cells[i] = vim.fn.strcharpart(line, chars - WIDTH + i - 1, 1)
    end
    return cells
  end
  local ramp = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
  local function rung(cell)
    for i, glyph in ipairs(ramp) do
      if cell == glyph then
        return i
      end
    end
    return 0
  end
  -- across a full scroll, how tall does each column ever get?
  local peak = {}
  for step = 0, 39 do
    local cells = bar_at(step / 40)
    for i, cell in ipairs(cells) do
      peak[i] = math.max(peak[i] or 0, rung(cell))
    end
  end
  -- the taper runs from the edge to the first column that ever reaches full
  local plateau
  for i = 1, #peak do
    if not plateau and peak[i] == #ramp then
      plateau = i
    end
  end
  -- Halfway through the taper it should be well past halfway up. A raised
  -- cosine is exactly half up at its midpoint (rung 4 of 8) and spends the
  -- first third of its width near zero; the quarter sine is at rung 6 there.
  -- Six passes with a rung of room either side of the two curves.
  local mid = plateau and peak[math.ceil(plateau / 2)] or 0
  check("the taper climbs fastest at the edge, not in the middle", mid >= 5)
  -- ...and it is still a taper, at both ends, not a square cut
  check("the first column still fades in", peak[1] < #ramp)
  check("the last column still fades out", (peak[#peak] or 0) < #ramp)
end

-- An animating row is a picture of one value, and a picture that wraps is two
-- pictures. A 98-cell reveal used to come out as two stacked waves mid-flight
-- and re-flow into a different shape the frame it settled; now it clips to one
-- line and the opening window uncovers the rest (Tony, reveal.mov).
do
  local long = '"llm-host.example.io/gateway/v2/ingest?region=us-west-2&trace=on"'
  local node = model.new({ name = "host", kind = "param", type = { display = "str", category = "builtin" } })
  node.example.llm = long
  local function frame(over)
    return render.render(
      { node },
      opts(vim.tbl_extend("force", {
        layout = "ledger",
        detail_all = true,
        max_width = 40,
        example_kind = "llm",
      }, over))
    )
  end
  local waiting = frame({
    example_pending = function()
      return true
    end,
  })
  local falling = frame({
    example_pending = function()
      return false
    end,
    example_reveal = function()
      return 0.35, 0.3
    end,
  })
  local settled = frame({
    example_pending = function()
      return false
    end,
  })
  local function example_lines(r)
    local n = 0
    for _, l in ipairs(r.lines) do
      if l:find("e.g.", 1, true) or l:find("[▁▂▃▄▅▆▇█]") then
        n = n + 1
      end
    end
    return n
  end
  check("a pending bar stays on one line", example_lines(waiting) == 1)
  check("...and so does a falling one", example_lines(falling) == 1)
  local widest = 0
  for _, l in ipairs(falling.lines) do
    widest = math.max(widest, vim.api.nvim_strwidth(l))
  end
  check("...clipped at the edge, never past it", widest <= 40)
  -- the pop-in of the second line is allowed, but only once it is real text
  check("the settled value is what wraps", #settled.lines > #falling.lines)
end

-- A half-uncovered value is a fragment: `_t.UriTy` parses as nothing, so it
-- painted flat grey until the frame it became whole and then flipped to full
-- color in one step. Each uncovered run names the whole value as its snippet
-- and the slice of it on screen, so characters arrive already colored.
do
  -- nothing the value contains appears in the annotation, so any injection
  -- naming part of it can only have come from the reveal
  local value = '"https://api.example.com/data"'
  local node = model.new({ name = "url", kind = "param", type = { display = "str", category = "builtin" } })
  node.example.llm = value
  local mid = render.render(
    { node },
    opts({
      example_kind = "llm",
      example_pending = function()
        return false
      end,
      example_reveal = function()
        return 0.6, 0.3
      end,
    })
  )
  local slices, sound = 0, true
  for _, ij in ipairs(mid.ts_injections) do
    if ij.text == value then
      slices = slices + 1
      local text = value:sub(ij.from + 1, ij.to)
      if mid.lines[ij.line + 1]:sub(ij.col_start + 1, ij.col_start + #text) ~= text then
        sound = false
      end
    end
  end
  check("an uncovered run injects the whole value", slices > 0)
  check("...at the offset it actually occupies", sound)
  local fragmented = false
  for _, ij in ipairs(mid.ts_injections) do
    if ij.text ~= value and value:find(ij.text, 1, true) then
      fragmented = true
    end
  end
  check("...and never as the fragment it looks like", not fragmented)
end

-- The window never shrinks, so the rules inside it must not either: a row that
-- re-flowed narrower on the frame it settled used to drag both section rules
-- in by a dozen columns while the frame around them stayed put.
do
  local node = model.new({ name = "x", kind = "param", type = { display = "str", category = "builtin" } })
  local function rule_width(min)
    local r = render.render({ node }, opts({ header = "f(x)", max_width = 90, window_width = min }))
    local widest = 0
    for _, l in ipairs(r.lines) do
      -- a rule is a line of nothing but the rule glyph (which is three bytes,
      -- so a Lua pattern can't say that)
      if #l > 0 and (l:gsub("─", "")) == "" then
        widest = math.max(widest, vim.api.nvim_strwidth(l))
      end
    end
    return widest
  end
  local natural = rule_width(nil)
  check("a rule with no floor still fits the content", natural > 0)
  check("a floor holds it open", rule_width(natural + 20) == natural + 20)
  check("...and a floor under the content is ignored", rule_width(4) == natural)
end

-- The pending bar used to be a fixed 28 cells while the landed value's wave
-- ran the whole row, so the frame that landed a batch stretched every wave
-- from two-thirds of the way across to the right edge in one step — a jump
-- across a third of the row, on the loudest frame of the transition (Tony,
-- reveal.mov f747->f748). The bar now runs out to the float's own edge, so
-- there is nothing left for the landing frame to move.
do
  local short = model.new({ name = "method", kind = "param", type = { display = "str", category = "builtin" } })
  short.example.llm = '"GET"'
  local W = 64
  local function frame(over)
    return render.render(
      { short },
      opts(vim.tbl_extend("force", {
        layout = "ledger",
        detail_all = true,
        max_width = 90,
        window_width = W,
        example_kind = "llm",
        example_phase = 0.25,
      }, over))
    )
  end
  local waiting = frame({
    example_pending = function()
      return true
    end,
  })
  local landing = frame({
    example_pending = function()
      return false
    end,
    -- progress 0 is the first frame of the fall: the wave has not moved yet,
    -- so it must still be the one the pending frame was showing
    example_reveal = function()
      return 0, 0.25
    end,
  })
  local function example_line(r)
    for _, l in ipairs(r.lines) do
      if l:find("e.g.", 1, true) then
        return l
      end
    end
  end
  local before, after = example_line(waiting), example_line(landing)
  check("a pending wave reaches the float's right edge", vim.api.nvim_strwidth(before) == W)
  -- the landing row may come up one cell short: its trailing cell is a drained
  -- blank with no character under it, and those are trimmed rather than left as
  -- trailing whitespace
  check("...and the landing frame is the same width", W - vim.api.nvim_strwidth(after) <= 1)
  -- every column that is a block in BOTH frames has to be the SAME block:
  -- that is what "nothing moved sideways" means, cell by cell
  local ramp = "[▁▂▃▄▅▆▇█]"
  local moved, compared = false, 0
  for i = 1, math.min(vim.fn.strchars(before), vim.fn.strchars(after)) do
    local a = vim.fn.strcharpart(before, i - 1, 1)
    local b = vim.fn.strcharpart(after, i - 1, 1)
    if a:match(ramp) and b:match(ramp) then
      compared = compared + 1
      if a ~= b then
        moved = true
      end
    end
  end
  check("...and every block that is still a block sits where it did", compared > 10 and not moved)
end

-- The wave is drawn out to the float's right edge — and during a reveal that
-- edge is moving, because the values that just landed are what widen the
-- float. Measured against it every frame, frozen_wave rescales its wavelength
-- to a longer run each time and the wave visibly stretches while it falls
-- (Tony). example_reveal hands back the width the wave froze at, and it keeps
-- that for the whole fall.
do
  local node = model.new({ name = "returns", kind = "return", type = { display = "R", category = "class" } })
  node.example.llm = 'Response(status_code=200, content=b"{\'key\': \'value\'}", headers={"Content-Type": "app"})'
  local FROZEN = 64
  local function example_at(window, froze_at)
    local r = render.render(
      { node },
      opts({
        layout = "ledger",
        detail_all = true,
        max_width = 90,
        window_width = window,
        example_kind = "llm",
        example_phase = 0.25,
        example_pending = function()
          return false
        end,
        -- one fixed instant of the fall, sampled while the window eases open
        example_reveal = function()
          return 0.3, 0.25, froze_at
        end,
      })
    )
    for _, l in ipairs(r.lines) do
      if l:find("e.g.", 1, true) then
        return l
      end
    end
  end
  local frozen = example_at(FROZEN, FROZEN)
  local same, differed = true, false
  for _, window in ipairs({ 71, 78, 85, 90 }) do
    if example_at(window, FROZEN) ~= frozen then
      same = false
    end
    -- the control: without a frozen width the wave follows the edge, which is
    -- what the stretch WAS. If this stops differing the test has gone vacuous.
    if example_at(window, nil) ~= example_at(FROZEN, nil) then
      differed = true
    end
  end
  check("a falling wave keeps its shape while the window opens", same)
  check("...where one measured against the moving edge would not", differed)
end

-- An atomic segment too wide to fit even on a continuation line used to spin
-- flow() forever: it kept asking for a fresh line, and a fresh line is never
-- narrower than its own chrome. render.render is pure and synchronous, so that
-- was a hung editor rather than a bad layout.
--
-- The origin tag is the atomic segment here. Examples used to be atomic too,
-- and were the easiest way in, but they split like ordinary text now — so the
-- example covers the split path and the origin covers the one that hung.
--
-- If this ever regresses the suite HANGS instead of failing, so the assertions
-- below are really just markers for whoever has to read the stack.
do
  local wide = model.new({ name = "host", kind = "param", type = { display = "str", category = "builtin" } })
  wide.example.heuristic = '"llm-host.example.io/gateway/v2/ingest?region=us-west-2"'
  wide.origin = "typescope.transport.gateway.RegionalIngestClientConfiguration"
  local narrow = render.render({ wide }, opts({ layout = "ledger", detail_all = true, max_width = 40 }))
  check("an example wider than the float wraps instead of hanging", #narrow.lines >= 2)
  local widest = 0
  for _, l in ipairs(narrow.lines) do
    widest = math.max(widest, vim.api.nvim_strwidth(l))
  end
  check("...and every wrapped line stays inside max_width", widest <= 40)
  -- deep chrome eats more of each continuation line; the guard has to be the
  -- prefix's real width, not a constant
  local parent = model.new({ name = "cfg", kind = "param", type = { display = "C", category = "struct" } })
  parent.state.expanded = true
  parent.children = { wide }
  local nested = render.render({ parent }, opts({ layout = "ledger", detail_all = true, max_width = 40 }))
  check("...at depth too", #nested.lines >= 3)
end

-- `e.g.` is a two-character label, and an atomic example left it alone on a
-- line of its own with the value hanging underneath — a whole line spent on
-- two characters in a float built to be compact. It also disagreed with the
-- animation immediately before it, which starts the value straight after the
-- label (Tony's call, reveal.mov f804->f805).
do
  local node = model.new({ name = "returns", kind = "return", type = { display = "R", category = "class" } })
  node.example.heuristic = "Response(status_code=200, content=b\"{'data': [{'id': 1, 'name': 'Item 1'}]}\")"
  local r = render.render({ node }, opts({ layout = "ledger", detail_all = true, max_width = 64 }))
  local label
  for _, l in ipairs(r.lines) do
    if l:find("e.g.", 1, true) then
      label = l
    end
  end
  check("the value starts on the e.g. line", label ~= nil and label:find("Response(", 1, true) ~= nil)
  -- and it uses that line: an atomic example left it two characters wide
  check("...filling it rather than leaving a stub", vim.api.nvim_strwidth(label) > 50)
end

-- The float opens into a landed batch's width instead of snapping there. The
-- e2e can only check THAT it grows; how it travels is pure math, so it gets
-- checked here where load can't blur it.
do
  local ease = require("typescope.interact")._grow_ease
  check("a grow starts where the window already is", ease(40, 80, 0) == 40)
  check("...and ends exactly on the target", ease(40, 80, 1) == 80)
  local prev, monotone, strictly_inside = 40, true, false
  for i = 1, 19 do
    local w = ease(40, 80, i / 20)
    if w < prev then
      monotone = false
    end
    if w > 40 and w < 80 then
      strictly_inside = true
    end
    prev = w
  end
  check("...never goes backwards", monotone)
  check("...and passes through intermediate widths (this is what a snap lacks)", strictly_inside)
  -- ease-OUT: the first half of the time covers well over half the distance
  check("most of the travel happens up front", ease(0, 100, 0.5) > 60)
  check("a zero-length grow is not a divide-by-anything", ease(50, 50, 0.5) == 50)
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

-- 13. find_break_point: the wrap decision every layout goes through
--
-- Five call sites depend on it — tree flow, docstring prose, header elision,
-- table cells, typing surface detail — and until now none of them tested it directly.
-- Its contract is easy to get wrong from the outside, so pin it here: `limit`
-- is a count of DISPLAY CELLS, the return is a 1-based INCLUSIVE BYTE index of
-- the last character to keep, and the caller is expected to strip the leading
-- whitespace from whatever remains.
--
-- That cells-in/bytes-out asymmetry is the seam both UTF-8 defects grew out
-- of, which is the other reason these live here rather than being asserted
-- through a whole rendered tree.
do
  local fbp = render._find_break_point

  -- a comma+space is an argument boundary in type syntax, so it wins even when
  -- a plain space sits further right (the loop scans down from `limit` and
  -- returns on the first comma, having merely REMEMBERED the spaces above it)
  check("comma-space beats a space further right", fbp("aaaa bbbb, cccc dddd", 20) == 10)
  check("...keeping the comma at end of line", ("aaaa bbbb, cccc dddd"):sub(1, 10) == "aaaa bbbb,")

  -- a plain space breaks BEFORE it, so the line never ends in a blank
  check("breaks before a space", fbp("aaaa bbbb cccc", 14) == 9)
  check("...leaving no trailing blank", ("aaaa bbbb cccc"):sub(1, 9) == "aaaa bbbb")

  -- nothing to break on: a hard cut at the limit
  check("no whitespace falls back to a hard cut", fbp("aaaaaaaaaaaaaa", 10) == 10)

  -- only the back half is searched: honouring a lone early break point would
  -- waste more vertical space than cutting mid-word does
  check("an early break point is ignored", fbp("ab cdefghijklmnop", 16) == 16)

  -- A cell budget spends the same on either. This used to be the tell for the
  -- byte-indexed scan (7bx.3): identical shape, identical limit, and the
  -- accented string came back 5 cells shorter because the window was measured
  -- in the wrong unit. Byte counts differ, cell counts must not.
  local ascii, accented = "aaaa bbbb cccc dddd eeee", "ääää bbbb cccc dddd eeee"
  local ascii_cut, accented_cut = fbp(ascii, 20), fbp(accented, 20)
  check("ascii fills the limit", vim.api.nvim_strwidth(ascii:sub(1, ascii_cut)) == 19)
  check("accented fills it too", vim.api.nvim_strwidth(accented:sub(1, accented_cut)) == 19)
  check("...taking more bytes to do it", accented_cut > ascii_cut)

  -- and the cut lands on a character boundary, never inside one — the other
  -- half of what the byte-indexed scan got wrong
  -- NOT vim.str_utfindex: its signature changed between 0.10 and 0.11 (the
  -- reason lsp.lua:33 carries a shim), and the 0.11 form errors on 0.10 —
  -- which took this whole file down on the CI floor while passing locally.
  -- str_utf_pos is stable across both; the lead byte gives the length, the
  -- same inline decode render.lua uses.
  local function ends_clean(s)
    if #s == 0 then
      return true
    end
    local at = vim.str_utf_pos(s)
    local start = at[#at]
    local lead = s:byte(start)
    local len = (lead < 0x80 and 1) or (lead < 0xE0 and 2) or (lead < 0xF0 and 3) or 4
    return start + len - 1 == #s
  end
  check("the cut never splits a character", ends_clean(accented:sub(1, accented_cut)))
  -- the no-whitespace fallback is where splitting actually used to happen:
  -- nothing to break on, so it returned the raw cell budget as a byte index
  local solid = "ünïcödé_ä_ö_ü_é_ändmöre"
  local solid_cut = fbp(solid, 12)
  check("...including on the no-whitespace fallback", ends_clean(solid:sub(1, solid_cut)))
  check("...which still fills the budget", vim.api.nvim_strwidth(solid:sub(1, solid_cut)) == 12)

  -- A budget of nothing. A node deep enough that its hanging indent is wider
  -- than the float hands place() a NEGATIVE avail, and every caller clamps
  -- with math.max(1, cut) so the wrap loop cannot spin. Returning the budget
  -- itself made that clamp land on byte 1 — inside the first character — so
  -- the answer has to be a whole character even when none of it fits.
  for _, budget in ipairs({ -17, -1, 0 }) do
    local cut = math.max(1, fbp("ünïcödé", budget))
    check(("a budget of %d still advances a whole character"):format(budget), cut == 2)
  end
end

-- 14. truncation counts cells, not bytes
--
-- Four places took a cell budget and used it as a byte index: the wrap point
-- (covered in 13), the ledger's type truncation, elide_members' no-separator
-- fallback, and the ledger's middle-ellipsis name cap. Each produced a broken
-- character on non-ASCII input, and every one of them passed the golden tests
-- above, because every fixture in this file is ASCII.
do
  local uni_type = "Literal['ünïcödé_ä', 'ünïcödé_ö', 'ünïcödé_ü', 'ünïcödé_é']"
  local uni_name = "ünïcödé_pärämètre_trës_löng_nöm_ïcï"
  local uni_doc =
    "Ouvre une connexion réseau — le délai s'exprime en secondes, au-delà de quoi l'appel échoue avec une erreur « timeout »."
  local uni_header = "ouvrir(möde, hôte_très_long, délai) -> Réponse"

  local function uni_roots()
    return {
      model.new({
        name = uni_name,
        kind = "param",
        type = { raw = uni_type, display = uni_type, category = "generic" },
        default = "'lecture'",
      }),
    }
  end

  -- Width is the variable that matters: a truncation only misbehaves at the
  -- widths where its cut happens to land mid-character, so a single fixture
  -- width proves almost nothing. This is the check that would have caught all
  -- three sites at once.
  for _, layout in ipairs({ "tree", "table", "ledger" }) do
    local worst = nil
    for w = 20, 80 do
      local res = render.render(uni_roots(), {
        style = styles.get("rounded"),
        max_width = w,
        layout = layout,
        align = "left",
        show_examples = false,
        example_kind = "heuristic",
        lang = "python",
        docstring = uni_doc,
        docstring_pos = "bottom",
        docstring_expanded = true,
        header = uni_header,
      })
      for i, line in ipairs(res.lines) do
        if not valid_utf8(line) then
          worst = worst or ("w=%d line %d %s"):format(w, i, vim.inspect(line))
        end
      end
    end
    check(("%s survives every width from 20 to 80 intact"):format(layout), worst == nil)
    if worst then
      print("  " .. worst)
    end
  end

  -- the ledger's middle-ellipsis keeps both ends of an identifier, and both
  -- ends are now measured in columns — so a unicode name spends its whole
  -- 24-cell cap instead of stopping around 13
  local ledger = render.render(uni_roots(), {
    style = styles.get("rounded"),
    max_width = 70,
    layout = "ledger",
    show_examples = false,
    example_kind = "heuristic",
    lang = "python",
  })
  check_utf8("ledger with a long unicode name", ledger)
  -- startswith/endswith, not :sub(1, 3) — a byte slice of "ünïcödé" yields
  -- "ün", which is how this assertion got written wrong the first time
  local shown = ledger.lines[1]:match("^· (%S+)")
  check("the capped name keeps both ends", vim.startswith(shown, "ünïcödé") and vim.endswith(shown, "nöm_ïcï"))
  check("...and spends its cell budget, not its byte budget", vim.api.nvim_strwidth(shown) == 24)

  -- elide_members' fallback: a shape with no bracket, no braces and no " | "
  -- has no member boundary to elide at, so it hard-cuts to the budget
  local aliased = model.new({
    name = "möde",
    kind = "param",
    type = { raw = "OpenTextMode", display = "OpenTextMode", category = "generic" },
    evaluated = "ünïcödé_ä_ünïcödé_ö_ünïcödé_ü_ünïcödé_é_ünïcödé_à_ünïcödé_è_ünïcödé_ù",
  })
  local narrow = render.typing_surface(aliased, {
    show_examples = false,
    example_kind = "heuristic",
    max_width = 28,
    style = styles.get("rounded"),
  })
  check_utf8("typing surface eliding an unbroken unicode shape", narrow)
  check_injections("typing surface eliding an unbroken unicode shape", narrow)
end

print(failures == 0 and "RENDER ALL PASS" or ("RENDER " .. failures .. " FAILURES"))
