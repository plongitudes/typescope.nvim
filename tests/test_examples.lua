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
      { name = "level", type = { display = "int", category = "builtin" }, default = "..." },
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
check("stub ... default still gets example", roots[1].children[6].example.heuristic == "42")

-- ollama prompt/parse round trip
local ollama = require("typescope.examples.ollama")
local prompt = ollama.prompt({
  { id = "config.host", name = "host", display = "str" },
  { id = "config.port", name = "port", display = "int" },
})
check("prompt lists dotted paths with types", prompt:find("config%.host: str") ~= nil and prompt:find("config%.port: int") ~= nil)

local parsed = ollama.parse([[
Here are the values:
```
config.host = "api.internal.example.io"
config.port = 8443
```
config.retry.backoff = 1.5
not a value line
]])
check("parse tolerates prose and fences", parsed["config.host"] == '"api.internal.example.io"')
check("parse handles ints and nested paths", parsed["config.port"] == "8443" and parsed["config.retry.backoff"] == "1.5")
check("parse skips non-matching lines", parsed["not"] == nil)

-- LLM caching discipline: misses get a sentinel (auto-run never re-asks),
-- E's retry_misses lifts it, and in-flight batches are never duplicated by
-- a reopen. Ollama's transport is faked at the module boundary.
do
  local examples = require("typescope.examples")
  local real_ollama = package.loaded["typescope.examples.ollama"]
  require("typescope.config").setup({ ollama = { enabled = true } })

  local calls = {} -- each entry: the ids asked for in that generate() call
  local respond -- set per-phase: fn(ids) -> response text (nil = defer)
  local deferred = nil
  package.loaded["typescope.examples.ollama"] = {
    prompt = function(specs)
      local ids = {}
      for _, s in ipairs(specs) do
        table.insert(ids, s.id)
      end
      return ids
    end,
    parse = real_ollama.parse,
    generate = function(ids, _, cb)
      table.insert(calls, ids)
      if respond then
        cb(respond(ids))
      else
        deferred = { ids = ids, cb = cb }
      end
    end,
  }

  local function forest()
    return {
      model.new({ name = "a", kind = "param", type = { display = "int", category = "builtin" } }),
      model.new({ name = "b", kind = "param", type = { display = "str", category = "builtin" } }),
    }
  end
  local token = require("typescope.async").token()

  -- phase 1: the model answers for `a` only → `b` is a MISS
  examples._clear_llm_cache()
  respond = function()
    return "a = 42"
  end
  local f1 = forest()
  examples.llm(f1, token, function() end)
  check("miss run: one request, a filled, b empty", #calls == 1 and f1[1].example.llm == "42" and f1[2].example.llm == nil)

  -- phase 2: a fresh open (same shapes) issues NO request — a from cache,
  -- b's sentinel stands
  local f2 = forest()
  local done_ok
  examples.llm(f2, token, function(ok)
    done_ok = ok
  end)
  check(
    "reopen run: served from cache + sentinel, zero requests",
    #calls == 1 and done_ok == true and f2[1].example.llm == "42" and f2[2].example.llm == nil
  )

  -- phase 3: retry_misses (the E press) lifts the sentinel — exactly the
  -- missed leaf is re-asked
  examples.retry_misses(f2)
  respond = function()
    return 'b = "beta"'
  end
  examples.llm(f2, token, function() end)
  check(
    "retry run: only the miss is re-asked",
    #calls == 2 and #calls[2] == 1 and calls[2][1] == "b" and f2[2].example.llm == '"beta"'
  )

  -- phase 4: a reopen while a batch is in flight does not duplicate it
  examples._clear_llm_cache()
  respond = nil -- defer: the batch stays in flight
  local f4 = forest()
  examples.llm(f4, token, function() end)
  local f5 = forest()
  examples.llm(f5, token, function() end)
  check("in-flight batch not duplicated by reopen", #calls == 3 and deferred ~= nil)
  -- 40u: the float open at landing time hears about the late batch through
  -- the landed subscription, and apply_cache copies the values onto its
  -- (fresh, unshared) tree — f5 was skipped by the dedup and got nothing
  local landed = 0
  examples.on_landed(function()
    landed = landed + 1
  end)
  deferred.cb('a = 7\nb = "late"')
  check("late batch notifies the subscriber", landed == 1)
  check(
    "apply_cache copies late values onto the reopened tree",
    examples.apply_cache(f5) == true and f5[1].example.llm == "7" and f5[2].example.llm == '"late"'
  )
  check("apply_cache no-ops when the tree already has the values", examples.apply_cache(f5) == false)
  examples.on_landed(nil)
  local f6 = forest()
  respond = function()
    return ""
  end
  examples.llm(f6, token, function() end)
  check(
    "late batch cached for the next open",
    #calls == 3 and f6[1].example.llm == "7" and f6[2].example.llm == '"late"'
  )

  package.loaded["typescope.examples.ollama"] = real_ollama
end

-- warmup residency (typescope.nvim-4sr): every open fires one empty-prompt
-- generate — it loads a cold model AND refreshes keep_alive on a warm one
-- (sliding-window residency), so no stale client-side flag can suppress
-- re-warming after an unload. Transport faked at vim.system.
do
  local real_system = vim.system
  local generates = 0
  local deferred_cb = nil -- when set-able, the request stays in flight
  local defer = false
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.system = function(_, _, cb)
    generates = generates + 1
    if defer then
      deferred_cb = cb
    else
      cb({ code = 0, stdout = "{}" })
    end
    return { wait = function() end }
  end

  local cfg = { host = "127.0.0.1", port = 9999, model = "testmodel", autostart = false, timeout_ms = 1000 }

  -- the stub responds synchronously but the module's callback is
  -- schedule_wrap'd, so each phase needs an unconditional wait to spin the
  -- event loop and let `warming` reset before the next open
  ollama.warmup(cfg)
  vim.wait(100)
  check("warmup fires the load", generates == 1, generates)

  -- a later open fires again — refreshes keep_alive when warm, re-warms
  -- when unloaded; the old sticky-flag code would no-op here
  ollama.warmup(cfg)
  vim.wait(100)
  check("every open re-fires (refresh / re-warm)", generates == 2, generates)

  -- overlapping opens while a request is in flight don't stack curls
  defer = true
  ollama.warmup(cfg)
  ollama.warmup(cfg)
  vim.wait(100)
  check("in-flight warmup dedups overlapping opens", generates == 3, generates)
  deferred_cb({ code = 0, stdout = "{}" })
  vim.wait(100)

  -- and once that flight lands, the next open fires again
  defer = false
  ollama.warmup(cfg)
  vim.wait(100)
  check("dedup releases after flight lands", generates == 4, generates)

  vim.system = real_system
end

print(failures == 0 and "EXAMPLES ALL PASS" or ("EXAMPLES " .. failures .. " FAILURES"))
