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
  '  ├─ host        str  "localhost"',
  '  ├─ ▾ retry     RetryPolicy',
  '  │ └─ max_attempts  int = 3',
  '  └─ timeout_ms  int | None NotRequired = None',
  '· opaque   Mystery [?]',
  '▸ returns  Response  (<CR> to expand)',
})

-- 2. right-aligned rounded, examples off
eq_lines(
  "right/rounded",
  render.render(tree(), opts({ style = styles.get("rounded"), align = "right", show_examples = false })).lines,
  {
    ' ▾ config  ServerConfig',
    '  ├─       host  str',
    '  ├─    ▾ retry  RetryPolicy',
    '  │ ╰─ max_attempts  int = 3',
    '  ╰─ timeout_ms  int | None NotRequired = None',
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
    '  ├─ host        str',
    '  ├─ ▾ retry     RetryPolicy',
    '  │ ╰─ max_attempts  int = 3',
    '  ╰─ timeout_ms  int | None NotRequired',
    '                  = None',
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
    '    host        str',
    '    - retry     RetryPolicy',
    '      max_attempts  int = 3',
    '    timeout_ms  int | None NotRequired = None',
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
    and h2.group == "TypeScopeField"
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
    '  ╰─ proxy  ClassVar[dict[weakref.ref[Any],',
    '            weakref.ref[Proxy[Any]]]]',
    '             ↑ReversibleProxy = {}',
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
    '  ├─ z  float',
    '  └─ x  int ↑Base',
  }
)

print(failures == 0 and "RENDER ALL PASS" or ("RENDER " .. failures .. " FAILURES"))
