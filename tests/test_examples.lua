-- Heuristic example-value coverage: the requirements' pattern table, token
-- matching semantics, type-variant selection, and the annotate walk.
--   nvim --headless --clean --cmd "set rtp+=." -c "luafile tests/test_examples.lua" -c "qa!"

local heuristic = require("typescope.examples.heuristic")
local examples = require("typescope.examples")
local model = require("typescope.model")

local failures = 0
local function check(desc, cond, got)
  print((cond and "PASS " or "FAIL ") .. desc .. (not cond and (" — got " .. tostring(got)) or ""))
  if not cond then
    failures = failures + 1
  end
end

-- name/type -> expected example (the requirements table + token semantics)
local cases = {
  -- requirements table rows
  { "host", "str", '"localhost"' },
  { "hostname", "str", '"localhost"' },
  { "server", "str", '"localhost"' },
  { "port", "int", "8080" },
  { "timeout", "float", "30.0" },
  { "ttl", "int", "30" },
  { "interval", "float", "30.0" },
  { "email", "str", '"user@example.com"' },
  { "url", "str", '"https://example.com"' },
  { "endpoint", "str", '"https://example.com"' },
  { "uri", "str", '"https://example.com"' },
  { "path", "str", '"/tmp/example"' },
  { "dir", "str", '"/tmp/example"' },
  { "file", "str", '"/tmp/example"' },
  { "name", "str", '"example"' },
  { "id", "str", '"a1b2c3d4"' },
  { "uuid", "str", '"a1b2c3d4"' },
  { "debug", "bool", "True" },
  { "count", "int", "42" },
  { "ratio", "float", "3.14" },
  { "label", "str", '"example"' },
  { "nothing", "None", "None" },
  -- token semantics: substring is not enough, tokens are
  { "timeout_ms", "int | None", "30" }, -- 'ms' head unknown → any-token fallback: timeout + int variant
  { "width", "int", "42" }, -- 'id' must NOT match inside 'width'
  { "user_id", "str", '"a1b2c3d4"' },
  -- head-noun-first (Tony, 2026-07-29): the rightmost token wins
  { "server_name", "str", '"example"' }, -- ...it IS a name (of a server)
  { "name_server", "str", '"localhost"' }, -- ...and this IS a server
  { "file_url", "str", '"https://example.com"' }, -- ...and this IS a url
  { "port", "str", '"8080"' }, -- by_type variant
  -- optional handling
  { "uds", "str | None", '"example"' }, -- known base type wins over None
  { "opaque_thing", "Widget | None", "None" }, -- unknown base: None is always valid
  { "widget", "Widget", nil }, -- nothing sensible: no example
}

for _, case in ipairs(cases) do
  local got = heuristic.value(case[1], case[2])
  check(("%s: %s -> %s"):format(case[1], case[2], tostring(case[3])), got == case[3], got)
end

-- annotate walk: leaves only; structs/methods/unresolved skipped
local roots = {
  model.new({
    name = "config",
    kind = "param",
    expanded = true,
    type = { display = "ServerConfig", category = "dataclass" },
    children = {
      { name = "host", type = { display = "str", category = "builtin" } },
      { name = "read", kind = "method", type = { display = "(p: str) -> bytes", category = "builtin" } },
      { name = "mystery", type = { display = "?", category = "unresolved" } },
      { name = "port", type = { display = "int", category = "builtin" }, default = "8000" },
      { name = "uds", type = { display = "str | None", category = "generic" }, default = "None" },
    },
  }),
}
examples.annotate(roots)
check("struct node gets no example", roots[1].example.heuristic == nil)
check("leaf annotated", roots[1].children[1].example.heuristic == '"localhost"')
check("method skipped", roots[1].children[2].example.heuristic == nil)
check("unresolved skipped", roots[1].children[3].example.heuristic == nil)
check("real default suppresses example", roots[1].children[4].example.heuristic == nil)
check("None default still gets example", roots[1].children[5].example.heuristic == '"example"')

print(failures == 0 and "EXAMPLES ALL PASS" or ("EXAMPLES " .. failures .. " FAILURES"))
