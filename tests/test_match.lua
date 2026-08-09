-- Client-side overload matching (h8h): match.pick over hand-built U4 group
-- nodes — no LSP, no TreeSitter. Run headless:
--   nvim --headless --clean --cmd "set rtp+=." \
--     -c "luafile tests/test_match.lua" -c "qa!"

local model = require("typescope.model")
local match = require("typescope.match")

local failures = 0
local function check(desc, cond)
  print((cond and "PASS " or "FAIL ") .. desc)
  if not cond then
    failures = failures + 1
  end
end

--- params: { name, display, mode = "*"|"/" } entries
local function group(params)
  local g = model.new({ name = "f", kind = "overload", type = { raw = "", display = "", category = "builtin" } })
  for _, p in ipairs(params) do
    model.add_child(
      g,
      model.new({
        name = p[1],
        kind = "param",
        type = { raw = p[2], display = p[2], category = "builtin" },
        pass_mode = p.mode,
      })
    )
  end
  return g
end

local function args(positional, keywords)
  local out = { positional = {}, keywords = keywords or {} }
  for _, k in ipairs(positional) do
    table.insert(out.positional, { kind = k })
  end
  return out
end

-- loguru's add in miniature: overloads differ only in sink's type
local loguru = {
  group({ { "sink", "TextIO | Writable | Callable[[Message], None] | Handler" }, { "level", "str | int", mode = "*" } }),
  group({ { "sink", "Callable[[Message], Awaitable[None]]" }, { "level", "str | int", mode = "*" } }),
  group({ { "sink", "str | PathLikeStr" }, { "level", "str | int", mode = "*" } }),
}
check("string literal picks the str overload past neutral protocols", match.pick(loguru, args({ "string" })) == 3)
check("unjudgeable arg keeps the first overload", match.pick(loguru, args({ "other" })) == 1)
check("empty call keeps the first overload", match.pick(loguru, args({})) == 1)
check("nil args (splat / no call) picks nothing", match.pick(loguru, nil) == nil)

-- scalar-only annotations are exhaustive: a wrong literal disqualifies
local fetch = {
  group({ { "key", "int" } }),
  group({ { "key", "str" }, { "default", "str" }, { "mode", "LoopMode" } }),
}
check("int literal picks the int overload", match.pick(fetch, args({ "integer" })) == 1)
check("string literal disqualifies scalar-only int", match.pick(fetch, args({ "string" })) == 2)
check("arity overflow disqualifies", match.pick(fetch, args({ "string", "string" })) == 2)
check("alias annotation stays neutral (never disqualifies)", match.pick(fetch, args({ "string" }, { { name = "mode", kind = "string" } })) == 2)

-- keyword-name membership
local kw = {
  group({ { "a", "int" } }),
  group({ { "a", "int" }, { "b", "str", mode = "*" } }),
}
check("unknown keyword disqualifies", match.pick(kw, args({}, { { name = "b", kind = "string" } })) == 2)
check("no group takes the keyword -> nil", match.pick(kw, args({}, { { name = "zzz", kind = "other" } })) == nil)

-- splat params absorb anything
local splat = {
  group({ { "a", "int" } }),
  group({ { "a", "int" }, { "*args", "Any" }, { "**kw", "Any" } }),
}
check("*args absorbs positional overflow", match.pick(splat, args({ "integer", "integer" })) == 2)
check("**kw absorbs unknown keywords", match.pick(splat, args({}, { { name = "zzz", kind = "other" } })) == 2)

-- kind edges
local edges = {
  group({ { "x", "float" } }),
  group({ { "x", "Any" } }),
  group({ { "m", "Literal[auto, manual]" } }),
}
check("int literal satisfies float", match.pick(edges, args({ "integer" })) == 1)
check("string literal scores Literal[...] over Any", match.pick(edges, args({ "string" })) == 3)

print(failures == 0 and "MATCH ALL PASS" or ("MATCH " .. failures .. " FAILURES"))
