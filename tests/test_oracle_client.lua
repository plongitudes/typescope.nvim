-- The Lua side of the oracle: setup() wires a FileType autocmd that attaches
-- typescope-oracle to Python buffers, lsp.oracle_for finds it, oracle.request
-- asks typescope/structure, the protocol check is pure and correct, and
-- :checkhealth's oracle section runs without error.
--
-- Needs a built binary (scripts/build-oracle.sh); skips itself otherwise.
local bin = vim.env.TYPESCOPE_ORACLE or (vim.fn.getcwd() .. "/oracle/target/debug/typescope-oracle")
if vim.fn.executable(bin) ~= 1 then
  print("SKIP test_oracle_client: no oracle binary at " .. bin .. " (scripts/build-oracle.sh)")
  print("ALL PASS")
  return
end

local failures = 0
local function check(cond, msg)
  if cond then
    print("ok   " .. msg)
  else
    failures = failures + 1
    print("FAIL " .. msg)
  end
end

local oracle = require("typescope.oracle")

-- protocol check is pure
do
  local ok, got = oracle.protocol_ok({ experimental = { typescope = { protocol = 1 } } })
  check(ok and got == 1, "protocol_ok accepts protocol 1")
  ok, got = oracle.protocol_ok({ experimental = { typescope = { protocol = 2 } } })
  check(not ok and got == 2, "protocol_ok refuses protocol 2")
  ok, got = oracle.protocol_ok({})
  check(not ok and got == nil, "protocol_ok refuses a server that says nothing")
end

-- locate honours oracle.path first
require("typescope").setup({ oracle = { path = bin } })
check(oracle.locate() == bin, "locate() returns oracle.path when set")
local version = oracle.version(bin)
check(
  type(version) == "string" and version:match("^typescope%-oracle %S+ %(protocol 1, pyrefly"),
  "version(): " .. tostring(version)
)

-- opening a python buffer attaches the client
vim.cmd.edit(vim.fn.getcwd() .. "/tests/fixtures/shapes.py")
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = "python" -- fires FileType → attach
local client
vim.wait(20000, function()
  client = require("typescope.lsp").oracle_for(bufnr)
  return client ~= nil and client.initialized
end, 50)
check(client ~= nil, "lsp.oracle_for(bufnr) finds the attached oracle")
check(client and client.name == "typescope-oracle", "client is named typescope-oracle")
check(oracle.mismatch == nil, "no protocol mismatch recorded")

-- basedpyright's slot is untouched: client_for wants definition support,
-- which the oracle deliberately does not advertise
check(
  require("typescope.lsp").client_for(bufnr) == nil,
  "lsp.client_for does not pick the oracle (no definition capability)"
)

-- a request through the wrapper
local class_line
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if l:match("^class ServerConfig") then
    class_line = i - 1
    break
  end
end
local token = require("typescope.async").token()
local done, err, scope
oracle.request(bufnr, { position = { line = class_line, character = 6 }, depth = 2 }, token, function(e, s)
  done, err, scope = true, e, s
end)
vim.wait(20000, function()
  return done
end, 10)
check(done and err == nil, "oracle.request answered (" .. vim.inspect(err) .. ")")
check(
  scope and scope.scope == "class" and scope.roots[1].name == "ServerConfig",
  "answer is ServerConfig's class scope"
)
check(scope and scope.roots[1].type.display == "(dataclass)", "class root row carries the category header")

-- null → nil through the wrapper
local done0, scope0 = false, "unset"
oracle.request(bufnr, { position = { line = 0, character = 0 } }, token, function(_, s)
  done0, scope0 = true, s
end)
vim.wait(10000, function()
  return done0
end, 10)
check(done0 and scope0 == nil, "nothing under the cursor → nil (not vim.NIL)")

-- health's oracle section runs without raising
local ok_health, herr = pcall(require("typescope.health").check)
check(ok_health, "health.check() runs (" .. tostring(herr) .. ")")

-- a second setup() re-creates the autocmd group without duplicating clients
require("typescope").setup({ oracle = { path = bin } })
vim.wait(500)
check(#vim.lsp.get_clients({ name = "typescope-oracle" }) == 1, "setup() twice keeps one oracle client")

if client then
  client:stop(true)
  vim.wait(2000, function()
    return vim.lsp.get_client_by_id(client.id) == nil
  end, 50)
end

if failures == 0 then
  print("ALL PASS")
else
  print(("FAILURES: %d"):format(failures))
end
