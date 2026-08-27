-- Capability sheet: asserts extract.type_at against the `typescope:` markers in
-- tests/fixtures/shapes.py. The fixture carries its own expectations, so the
-- spec and the sample cannot drift apart. Run headless:
--   nvim --headless --clean \
--     --cmd "set rtp+=. rtp+=~/.local/share/nvim/site" \
--     -c "luafile tests/test_shapes.lua" -c "qa!"
--
-- Markers that say fields=NONE are documenting a real gap. When one is closed,
-- this file goes red until the marker is updated — which is the point of
-- recording the gaps rather than omitting them.

local py = require("typescope.extract.python")

local failures = 0
local function check(desc, cond, detail)
  print((cond and "PASS " or "FAIL ") .. desc .. (not cond and detail and (" — " .. detail) or ""))
  if not cond then
    failures = failures + 1
  end
end

local path = vim.fn.getcwd() .. "/tests/fixtures/shapes.py"
local src = table.concat(vim.fn.readfile(path), "\n")
local lines = vim.split(src, "\n")

--- Every marker, paired with the class it annotates: the next `class NAME` at or
--- below it, skipping the comment block and any decorators between the two.
---@return { row: integer, col: integer, name: string, category: string, fields: string[] }[]
local function markers()
  local out = {}
  for i, line in ipairs(lines) do
    local body = line:match("^#%s*typescope:%s*(.+)$")
    if body then
      local category = body:match("category=([%w_]+)")
      local fields_raw = body:match("fields=([^%s]+)")
      local methods_raw = body:match("methods=([^%s]+)")
      local name, row, col
      for j = i + 1, #lines do
        local cname, at = lines[j]:match("^class%s+([%w_]+)"), lines[j]:find("class%s")
        if cname then
          -- 0-based row, and a column INSIDE the class name, which is what
          -- type_at resolves from
          name, row, col = cname, j - 1, at + 5
          break
        end
      end
      local function split(raw)
        local out2 = {}
        if raw and raw ~= "NONE" then
          for f in raw:gmatch("[^,]+") do
            table.insert(out2, f)
          end
        end
        return out2
      end
      local fields = split(fields_raw)
      table.insert(out, {
        row = row,
        col = col,
        name = name,
        category = category,
        fields = fields,
        methods = methods_raw and split(methods_raw) or nil,
        line = i,
      })
    end
  end
  return out
end

local found = markers()

-- Guard the harness itself: a parser that silently matched nothing would report
-- a clean run over zero assertions, which is the failure mode a marker-driven
-- test is most exposed to.
check("the fixture yields markers", #found >= 12, ("only %d found"):format(#found))
for _, m in ipairs(found) do
  if not m.name then
    check(("marker on line %d binds to a class"):format(m.line), false, "no class beneath it")
  end
  if not m.category then
    check(("marker on line %d declares a category"):format(m.line), false, "no category= key")
  end
end

for _, m in ipairs(found) do
  if m.name and m.category then
    local got = py.type_at(src, m.row, m.col)
    if not got then
      check(("%s resolves"):format(m.name), false, "type_at returned nil")
    else
      check(
        ("%s is a %s"):format(m.name, m.category),
        got.category == m.category,
        ("got %s"):format(tostring(got.category))
      )
      local names = {}
      for _, f in ipairs(got.fields) do
        table.insert(names, f.name)
      end
      local want, have = table.concat(m.fields, ","), table.concat(names, ",")
      check(("%s fields: %s"):format(m.name, want == "" and "none" or want), want == have, ("got [%s]"):format(have))
      -- only Protocols collect methods, so only markers that claim them assert
      if m.methods then
        local mnames = {}
        for _, fn in ipairs(got.methods) do
          table.insert(mnames, fn.name)
        end
        local mw, mh = table.concat(m.methods, ","), table.concat(mnames, ",")
        check(("%s methods: %s"):format(m.name, mw), mw == mh, ("got [%s]"):format(mh))
      end
    end
  end
end

-- The inheritance marker also claims a base; own fields come first, inherited
-- ones are merged by resolve.lua rather than by type_at, so this asserts only
-- that the base is REPORTED for chasing.
for _, m in ipairs(found) do
  if m.name == "DerivedConfig" then
    local got = py.type_at(src, m.row, m.col)
    local bases = {}
    for _, b in ipairs(got and got.bases or {}) do
      table.insert(bases, b.name)
    end
    check(
      "DerivedConfig reports BaseConfig for chasing",
      table.concat(bases, ",") == "BaseConfig",
      table.concat(bases, ",")
    )
  end
end

-- Marker bases are structural, not inheritance to chase: a TypedDict must not
-- report TypedDict as a base, or resolve would try to walk into typing.
for _, m in ipairs(found) do
  if m.name == "Record" or m.name == "Point" or m.name == "Backend" then
    local got = py.type_at(src, m.row, m.col)
    check(("%s reports no chaseable base"):format(m.name), #(got and got.bases or {}) == 0)
  end
end

if failures == 0 then
  print("SHAPES ALL PASS")
else
  print(("SHAPES %d FAILURES"):format(failures))
end
