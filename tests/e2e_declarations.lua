-- End-to-end test of the DECLARATION paths in resolve.function_scope, against
-- the real oracle binary (the suite skips itself without one). Run headless:
--   nvim --headless --clean \
--     --cmd "set rtp+=. rtp+=~/.local/share/nvim/site" \
--     -c "luafile tests/e2e_declarations.lua" -c "qa!"
--
-- These paths answer "what was this symbol declared as", and the failure they
-- exist to prevent is answering with the thing AROUND the symbol instead: the
-- enclosing method for an attribute, the enclosing class for a class-body
-- name. Every case below pins which of the two came back, because both shapes
-- are non-empty floats and a wrong one looks perfectly healthy on screen.
--
-- Own fixture directory on purpose: the mock resolves by grepping every .py in
-- the dir it is given, so sharing tests/fixtures would let a name here change
-- which site an existing suite resolves to.

local root = vim.fn.getcwd()
local fixture_dir = root .. "/tests/fixtures/declarations"

require("typescope").setup({ ui = { layout = "tree" } })

local failures = 0
local function check(desc, cond)
  print((cond and "PASS " or "FAIL ") .. desc)
  if not cond then
    failures = failures + 1
  end
end

local resolve = require("typescope.resolve")
local async = require("typescope.async")
local model = require("typescope.model")

vim.cmd.edit(fixture_dir .. "/sample.py")
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = "python" -- setup() attaches the oracle on FileType
local client
vim.wait(20000, function()
  client = require("typescope.lsp").oracle_for(bufnr)
  return client ~= nil and client.initialized
end, 50)
check("oracle attached", client ~= nil)

---------------------------------------------------------------- driving resolve

--- Resolve with the cursor on `needle`, within the line containing `pat`.
--- Returns the pipeline's own three values rather than rendered text: a
--- decline and a one-row float both put a single line on screen, and only
--- `why` tells them apart.
local function resolve_at(pat, needle)
  local row, text
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:find(pat, 1, true) then
      row, text = i, l
      break
    end
  end
  assert(row, "no fixture line matching " .. pat)
  local col = assert(text:find(needle, 1, true), needle .. " not on that line") - 1

  resolve.clear_cache() -- each case asks its own question, not a warm one
  local out, done = {}, false
  async.run(function()
    out.roots, out.meta, out.why = resolve.function_scope(client, bufnr, 0, async.token(), { row, col })
    done = true
  end)
  vim.wait(20000, function()
    return done
  end)
  out.finished = done
  return out
end

local function names(nodes)
  local out = {}
  for _, n in ipairs(nodes or {}) do
    table.insert(out, n.name)
  end
  return table.concat(out, ",")
end

--------------------------------------------------- the class IS the answer

-- The one shape that does NOT draw the declaration: when the annotation is
-- exactly one drawable class, that class IS the answer and heads the float.
local bar = resolve_at("self.bar: Bar", "bar")
check(
  "annotated attribute resolves to its class, not to __init__",
  bar.roots ~= nil and not names(bar.roots):find("__init__")
)
check("  ... the class heads the float", bar.roots and #bar.roots == 1 and bar.roots[1].name == "Bar")
check("  ... with its own fields beneath it", bar.roots and names(bar.roots[1].children) == "label,count")

------------------------------------------- nothing to draw still draws a row

-- Path has plenty of structure in typeshed; a typeshed class is a terminal
-- leaf (vocabulary, not shape), so the declaration is the row.
local blocked = resolve_at("self.blocked: Path", "blocked")
check("typeshed-blocked attribute draws one row", blocked.roots and #blocked.roots == 1)
check("  ... named for the declaration, not the method", blocked.roots and blocked.roots[1].name == "self.blocked")
check("  ... carrying the declared type", blocked.roots and blocked.roots[1].type.display == "Path")
check("  ... with nothing invented beneath it", blocked.roots and #blocked.roots[1].children == 0)
check("  ... and it is a float, not a decline", blocked.why == nil)

local strong = resolve_at("self.strong: str", "strong")
check("pure builtin annotation draws one row", strong.roots and #strong.roots == 1 and strong.why == nil)
check("  ... with the builtin as its type", strong.roots and strong.roots[1].type.display == "str")

local empty = resolve_at("self.empty: Empty", "empty")
check("empty class draws the declaration instead", empty.roots and #empty.roots == 1 and empty.why == nil)
check("  ... named for the declaration", empty.roots and empty.roots[1].name == "self.empty")

------------------------------------------------------ wrapped annotations

local mapping = resolve_at("self.mapping:", "mapping")
check("wrapper keeps the declaration as the root row", mapping.roots and #mapping.roots == 1)
check(
  "  ... heading the float with the type the symbol HAS",
  mapping.roots and mapping.roots[1].type.display == "dict[str, Bar]"
)
check("  ... and nesting the member class beneath it", mapping.roots and #mapping.roots[1].children > 0)

-------------------------------------- declarations with no enclosing function

-- The regression guards. Neither of these sits inside a method, so the walk
-- that answers with __init__ finds nothing -- and the fall-through that used
-- to follow answered with the enclosing CLASS, or with nothing at all.
local in_class = resolve_at("    handle: Path", "handle")
check("class-body declaration draws itself", in_class.roots and #in_class.roots == 1 and in_class.why == nil)
check("  ... not the enclosing class's fields", in_class.roots and in_class.roots[1].name == "handle")
check("  ... and not Holder's other members", names(in_class.roots):find("bar") == nil)

local at_module = resolve_at("LOG: Path", "LOG")
check("module-level declaration draws itself", at_module.roots and #at_module.roots == 1)
check("  ... rather than ending at absent", at_module.why == nil)
check("  ... named for the declaration", at_module.roots and at_module.roots[1].name == "LOG")

-- (The "one definition round trip per position" check went with the
-- definition chase: the oracle answers a declaration in one request.)

---------------------------------------------------------------------- node ids

-- Ids are dot-separated paths, and names carry dots from two directions: an
-- attribute declaration is raw source text, an annotation ref keeps its dotted
-- module vocabulary. Both have to survive as ONE segment.
check("declaration id carries no dot", blocked.roots and not blocked.roots[1].id:find(".", 1, true))
check(
  "collapse-all finds the root by its first segment",
  blocked.roots and blocked.roots[1].id:match("^[^.]+") == blocked.roots[1].id
)

local parent = model.new({ name = "self.foo" })
local left = model.new({ name = "pkg.Config" })
local right = model.new({ name = "other.Config" })
model.add_child(parent, left)
model.add_child(parent, right)
local leaf = model.new({ name = "x" })
model.add_child(left, leaf)

check("dotted ref names stay distinct as siblings", left.id ~= right.id)
check("nested id remains a resolvable path", model.parent({ parent }, leaf.id) == left)
check("root of a dotted name is one segment", parent.id:match("^[^.]+") == parent.id)
check(
  "a subscripted name keeps its dot out of the id",
  not model.new({ name = 'self.data["k"]' }).id:find(".", 1, true)
)

------------------------------------------------------------------------ report

if failures == 0 then
  print("DECLARATIONS ALL PASS")
else
  print(("DECLARATIONS FAILURES: %d"):format(failures))
end
