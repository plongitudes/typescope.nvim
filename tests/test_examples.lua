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
check(
  "prompt lists dotted paths with types",
  prompt:find("config%.host: str") ~= nil and prompt:find("config%.port: int") ~= nil
)

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
check(
  "parse handles ints and nested paths",
  parsed["config.port"] == "8443" and parsed["config.retry.backoff"] == "1.5"
)
check("parse skips non-matching lines", parsed["not"] == nil)

-- The escape hatch (typescope.nvim-o6s). Without a way to decline, the prompt's
-- "EXACTLY one line per field" forces a value for every field, so a type that
-- admits no literal gets one invented from the field's NAME — a confident wrong
-- answer rather than an absent one.
check("prompt offers a way to decline", prompt:find("SKIP") ~= nil)

-- the padded line is concatenated rather than written into a long string so the
-- trailing whitespace it is testing survives an editor, and a linter, untouched
local declined = ollama.parse(table.concat({
  'host = "localhost"',
  "receiver = SKIP",
  "  padded = SKIP  ",
  'label = "SKIP"',
  "port = 8080",
}, "\n"))
check("a bare SKIP is dropped", declined.receiver == nil)
check("...even padded", declined.padded == nil)
-- compared unquoted and exact, so a str field may legitimately answer "SKIP"
check('a quoted "SKIP" is a real value', declined.label == '"SKIP"')
check("declining does not disturb its neighbours", declined.host == '"localhost"' and declined.port == "8080")

-- Types that admit no literal are never asked about at all. pyright renders a
-- receiver as Self@Bar and a bound TypeVar as T@func; neither is a Python type.
do
  local model = require("typescope.model")
  local examples = require("typescope.examples")
  local function heuristic_for(name, display)
    local n = model.new({ name = name, kind = "param", type = { display = display, category = "builtin" } })
    examples.annotate({ n })
    return n.example.heuristic
  end
  check("a receiver is not asked for an example", heuristic_for("numpy_test", "Self@Bar") == nil)
  check("nor a bound TypeVar", heuristic_for("email", "T@handler") == nil)
  check("nor one nested in a generic", heuristic_for("email", "list[Self@Bar]") == nil)
  -- the two shapes a careless pattern would break: an @ inside a string literal,
  -- and a class whose name merely starts with Self
  check(
    "a Literal containing an @ is still asked",
    heuristic_for("email", 'Literal["user@example.com"]') == '"user@example.com"'
  )
  check("a class named SelfEmployed is still asked", heuristic_for("email", "SelfEmployed") ~= nil)

  -- An unspecified default is exactly the case worth showing an example FOR, so
  -- neither spelling of the stub placeholder may suppress one. The normalised
  -- glyph arrived with the render fix and would otherwise have read as a real
  -- default here, silently dropping the example from every stub-defaulted param.
  local function with_default(default)
    local n = model.new({
      name = "level",
      kind = "param",
      default = default,
      type = { display = "str", category = "builtin" },
    })
    examples.annotate({ n })
    return n.example.heuristic
  end
  check("the normalised stub default still gets an example", with_default("…") ~= nil)
  check("...and the raw one", with_default("...") ~= nil)
  check("a None default still gets one", with_default("None") ~= nil)
  check("a REAL default suppresses it", with_default('"WARN"') == nil)
end

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
  check(
    "miss run: one request, a filled, b empty",
    #calls == 1 and f1[1].example.llm == "42" and f1[2].example.llm == nil
  )

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

  -- 38c: the pending set a run claims is the WHOLE queue, not just the eight
  -- leaves in the air. Two things ride on it: a reopen mid-run must skip
  -- leaves the run hasn't dispatched yet, and every not-yet-landed leaf
  -- breathes (render asks through opts.example_pending).
  examples._clear_llm_cache()
  respond = nil
  local function wide()
    local nodes = {}
    for i = 1, 10 do
      table.insert(
        nodes,
        model.new({ name = "p" .. i, kind = "param", type = { display = "int", category = "builtin" } })
      )
    end
    return nodes
  end
  local w1 = wide()
  local before = #calls
  examples.llm(w1, token, function() end)
  check("wide run dispatches one batch of 8", #calls == before + 1 and #calls[#calls] == 8)
  check("dispatched leaf is awaiting", examples.awaiting(w1[1]))
  check("queued-but-undispatched leaf is awaiting too", examples.awaiting(w1[10]))
  check("any_awaiting true while values are coming", examples.any_awaiting())

  examples.llm(wide(), token, function() end)
  check("reopen mid-run re-asks nothing, queue tail included", #calls == before + 1)

  local batch1 = deferred
  deferred = nil
  batch1.cb("p1 = 1\np2 = 2\np3 = 3\np4 = 4\np5 = 5\np6 = 6\np7 = 7\np8 = 8")
  check("landed leaf stops being pending", not examples.awaiting(w1[1]) and w1[1].example.llm == "1")
  check("the queue tail is still pending", examples.awaiting(w1[10]) and examples.any_awaiting())

  -- a transport failure aborts the chain: leaves nobody will ever ask about
  -- must be released, or they stay unaskable (and breathing) all session
  deferred.cb(nil)
  check("aborted chain releases the whole queue", not examples.any_awaiting() and not examples.awaiting(w1[10]))
  respond = function()
    return ""
  end
  examples.llm(wide(), token, function() end)
  check("transport failure leaves no sentinel — the tail is re-asked", #calls == before + 3)

  -- a batch that fills NOTHING still has to reach the float: its leaves
  -- stopped being pending, so the placeholder bars 38c painted for them are
  -- stale the moment it resolves. The retry path makes this the ordinary
  -- case, not a corner — E re-asks only the leaves that already whiffed.
  examples._clear_llm_cache()
  local empty_landings = 0
  examples.on_landed(function()
    empty_landings = empty_landings + 1
  end)
  respond = function()
    return "" -- asked, answered nothing usable: every leaf a MISS
  end
  local m1 = forest()
  local miss_ok, miss_err
  examples.llm(m1, token, function(ok, err)
    miss_ok, miss_err = ok, err
  end)
  check("an all-miss batch still notifies the subscriber", empty_landings == 1)
  check("...and still reports the failure", miss_ok == false and miss_err ~= nil)
  check("...leaving nothing pending", not examples.any_awaiting())
  examples.on_landed(nil)

  package.loaded["typescope.examples.ollama"] = real_ollama
end

-- warmup residency (typescope.nvim-4sr): every open fires one empty-prompt
-- generate — it loads a cold model AND refreshes keep_alive on a warm one
-- (sliding-window residency), so no stale client-side flag can suppress
-- re-warming after an unload. Transport faked at vim.system.
do
  local real_system = vim.system
  local generates = 0
  local probes = 0
  local deferred_cb = nil -- when set-able, the request stays in flight
  local defer = false
  -- warmup probes /api/version for liveness before it sends the load, so the
  -- stub has to tell the two apart: counting every subprocess would count the
  -- probe as a load. What this block asserts is the number of LOADS — one per
  -- open, no client-side flag suppressing a re-warm — which is unchanged by
  -- the probe existing.
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.system = function(cmd, _, cb)
    local is_probe = false
    for _, arg in ipairs(cmd) do
      if type(arg) == "string" and arg:find("/api/version", 1, true) then
        is_probe = true
      end
    end
    if is_probe then
      probes = probes + 1
      cb({ code = 0, stdout = "{}" }) -- server alive; warmup proceeds to load
      return { wait = function() end }
    end
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

  -- and the liveness probe really did run ahead of each of those loads
  check("each warmup probes before loading", probes == generates, probes)

  vim.system = real_system
end

-- Streamed transport: /api/generate replies as JSON-lines, one object per
-- token, done=true on the last. The whole point is that a slow generation is
-- indistinguishable from a fast one here -- only silence fails -- so these
-- assert assembly and truncation, not timing.
do
  local ollama = require("typescope.examples.ollama")
  local real_system = vim.system
  local cfg = { host = "127.0.0.1", port = 9999, model = "testmodel", autostart = false, timeout_ms = 1000 }

  local function stub(out)
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(_, _, cb)
      cb(out)
      return { wait = function() end }
    end
  end

  local function gen()
    local got, err, fired = nil, nil, false
    ollama.generate("p", cfg, function(r, e)
      got, err, fired = r, e, true
    end)
    vim.wait(200, function()
      return fired
    end)
    return got, err, fired
  end

  -- happy path: many chunks concatenate in order
  stub({
    code = 0,
    stdout = table.concat({
      '{"response":"Wid","done":false}',
      '{"response":"get","done":false}',
      '{"response":"(1)","done":false}',
      '{"response":"","done":true}',
    }, "\n"),
  })
  local got, err = gen()
  check("streamed chunks assemble in order", got == "Widget(1)" and err == nil, tostring(got) .. "/" .. tostring(err))

  -- a stream cut before done= is a truncated answer, not a short one
  stub({ code = 0, stdout = '{"response":"Wid","done":false}\n{"response":"get","done":false}' })
  local tgot, terr = gen()
  check("truncated stream is an error, not a fragment", tgot == nil and terr ~= nil, tostring(tgot))

  -- a single trailing newline / blank lines must not break assembly
  stub({ code = 0, stdout = '{"response":"ok","done":false}\n\n{"response":"","done":true}\n' })
  local bgot = gen()
  check("blank lines in the stream are skipped", bgot == "ok", tostring(bgot))

  -- silence (curl 28) retries once, then reports
  local attempts = 0
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.system = function(_, _, cb)
    attempts = attempts + 1
    cb({ code = 28, stdout = "" })
    return { wait = function() end }
  end
  local sgot, serr, sfired = gen()
  check("stall retries exactly once then errors", sfired and sgot == nil and serr ~= nil and attempts == 2, attempts)

  vim.system = real_system
end

-- ensure_server must answer everyone who asked. Transport faked at
-- vim.system, and the probe is HELD in flight rather than answered, which is
-- both what creates the re-entry window and what guarantees nothing here ever
-- spawns a real `ollama serve`.
--
-- The callback is load-bearing rather than advisory: warmup's done() is what
-- clears `warming` and drains warm_waiters, so dropping one parks every later
-- generate for the session and leaves the pending bars breathing until
-- PENDING_MAX_MS retires the clock.
do
  local real_system = vim.system
  local probes, held = 0, nil
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.system = function(_, _, cb)
    probes = probes + 1
    held = cb -- never answered until we say so; no subprocess is ever started
    return { wait = function() end }
  end

  local cfg = { host = "127.0.0.1", port = 9998, model = "testmodel", autostart = false, timeout_ms = 1000 }
  local answers = {}
  local function ask()
    ollama.ensure_server(cfg, function(ready)
      table.insert(answers, ready)
    end)
  end
  ask()
  ask()
  check("a caller arriving mid-flight does not start a second probe", probes == 1, probes)
  check("...and nobody has been answered yet", #answers == 0, #answers)

  held({ code = 0, stdout = "{}" }) -- the server answers: it is up
  vim.wait(100)
  check("both callers are answered", #answers == 2, #answers)
  check("...with the real result, not a re-entry brush-off", answers[1] == true and answers[2] == true)

  -- the queue has to release, or the NEXT run inherits a stale waiter list
  answers = {}
  ask()
  check("a later run probes afresh", probes == 2, probes)
  held({ code = 0, stdout = "{}" })
  vim.wait(100)
  check("...and answers only its own caller", #answers == 1, #answers)

  vim.system = real_system
end

print(failures == 0 and "EXAMPLES ALL PASS" or ("EXAMPLES " .. failures .. " FAILURES"))
