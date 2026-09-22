-- The three row kinds the oracle adds (design/oracle.md §4, decision 4):
-- a property and an enum member are data rows with their own highlight, and
-- `methods (n)` is a collapsed group that opens to method rows. Pure render:
-- no binary, no LSP. The printed floats double as the text "screenshots" —
-- headless geometry probes lie, but row CONTENT is exactly what the buffer
-- holds, and these rows change content, not geometry.
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

local function tree()
  return {
    model.new({
      name = "resp",
      kind = "field",
      expanded = true,
      type = { raw = "Response", display = "Response", category = "class" },
      children = {
        { name = "status", kind = "field", type = { raw = "int", display = "int", category = "builtin" } },
        { name = "ok", kind = "property", type = { raw = "bool", display = "bool", category = "builtin" } },
        {
          name = "parsed",
          kind = "field",
          inferred = true,
          evaluated = "dict[str, int]",
          type = { raw = "dict[str, int]", display = "Any", category = "builtin" },
        },
        {
          name = "methods",
          kind = "group",
          type = { raw = "(2)", display = "(2)", category = "group" },
          children = {
            {
              name = "json",
              kind = "method",
              type = { raw = "() -> dict", display = "() -> dict", category = "function" },
            },
            {
              name = "raise_for_status",
              kind = "method",
              type = { raw = "() -> None", display = "() -> None", category = "function" },
            },
          },
        },
      },
    }),
    model.new({
      name = "color",
      kind = "param",
      expanded = true,
      type = { raw = "Color", display = "Color", category = "enum" },
      children = {
        {
          name = "RED",
          kind = "enum_member",
          default = "1",
          type = { raw = "Color", display = "Color", category = "enum" },
        },
        {
          name = "GREEN",
          kind = "enum_member",
          default = "2",
          type = { raw = "Color", display = "Color", category = "enum" },
        },
      },
    }),
  }
end

local function opts(over)
  return vim.tbl_extend("force", {
    style = styles.get("unicode"),
    max_width = 70,
    align = "left",
    show_examples = false,
    example_kind = "heuristic",
    lang = "python",
  }, over or {})
end

local function groups_of(result, text)
  -- highlight groups applied to the first line containing `text`
  local out = {}
  for i, l in ipairs(result.lines) do
    if l:find(text, 1, true) then
      for _, h in ipairs(result.highlights) do
        if h.line == i - 1 or h[1] == i - 1 then
          out[h.group or h[2] or h.hl_group or "?"] = true
        end
      end
      break
    end
  end
  return out
end

for _, layout in ipairs({ "ledger", "tree" }) do
  local result = render.render(tree(), opts({ layout = layout }))
  local text = table.concat(result.lines, "\n")
  print("---- " .. layout .. " ----")
  print(text)
  check(layout .. ": property row present", text:find("ok", 1, true) ~= nil and text:find("bool", 1, true) ~= nil)
  -- the ledger keeps ≈ for its cursor-follow detail block and shows the
  -- evaluation as the row's type; the tree draws ≈ inline. Neither says Any.
  if layout == "tree" then
    check(layout .. ": inferred row draws ≈ dict[str, int] inline", text:find("≈ dict[str, int]", 1, true) ~= nil)
  else
    check(
      layout .. ": inferred row shows the evaluation as its type",
      text:find("parsed   dict[str, int]", 1, true) ~= nil
    )
  end
  check(layout .. ": no row says Any", not text:find("Any", 1, true))
  check(
    layout .. ": methods group row collapsed by default",
    text:find("methods", 1, true) ~= nil and not text:find("raise_for_status", 1, true)
  )
  check(
    layout .. ": enum members with values",
    text:find("RED", 1, true) ~= nil and text:find("= 1", 1, true) ~= nil and text:find("GREEN", 1, true) ~= nil
  )
  check(layout .. ": property name highlighted TypeScopeProperty", groups_of(result, "ok")["TypeScopeProperty"] == true)
  check(
    layout .. ": enum member highlighted TypeScopeEnumMember",
    groups_of(result, "RED")["TypeScopeEnumMember"] == true
  )
  check(layout .. ": group highlighted TypeScopeGroup", groups_of(result, "methods")["TypeScopeGroup"] == true)

  -- open the group: method rows appear, keep block colouring (no injection)
  local roots = tree()
  roots[1].children[4].state.expanded = true
  local opened = render.render(roots, opts({ layout = layout }))
  local otext = table.concat(opened.lines, "\n")
  print("---- " .. layout .. " (methods open) ----")
  print(otext)
  check(
    layout .. ": opened group lists its methods",
    otext:find("raise_for_status", 1, true) ~= nil and otext:find("() -> None", 1, true) ~= nil
  )
  local injected = false
  for _, inj in ipairs(opened.ts_injections or {}) do
    if inj.text and inj.text:find("(2)", 1, true) then
      injected = true
    end
  end
  check(layout .. ": the group's count is not treesitter-injected", not injected)
end

-- examples never target an enum member or a group
local eligible = require("typescope.examples")
local roots = tree()
eligible.annotate(roots)
local red = roots[2].children[1]
check(
  "no example generated for an enum member",
  red.example == nil or (red.example.heuristic == nil and red.example.llm == nil)
)
local group = roots[1].children[4]
check("no example generated for the methods group", group.example == nil or group.example.heuristic == nil)

if failures == 0 then
  print("ALL PASS")
else
  print(("FAILURES: %d"):format(failures))
end
