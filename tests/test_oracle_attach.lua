-- The oracle binary attaches through nvim's own LSP client and identifies
-- itself: serverInfo.name, a protocol number in the experimental capability,
-- full document sync, and NO capability that would compete with basedpyright.
-- A typescope/structure request is answered (null until beads 2 and 4).
--
-- Needs a built binary: scripts/build-oracle.sh. tests/run.sh skips this
-- suite with a notice when there is none, so the pure-Lua suites do not need
-- a Rust toolchain.
local bin = vim.env.TYPESCOPE_ORACLE or (vim.fn.getcwd() .. "/oracle/target/debug/typescope-oracle")
if vim.fn.executable(bin) ~= 1 then
  print("SKIP test_oracle_attach: no oracle binary at " .. bin .. " (scripts/build-oracle.sh)")
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

local fixture = vim.fn.getcwd() .. "/tests/fixtures/shapes.py"
vim.cmd.edit(fixture)
local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = "python"

local client_id = vim.lsp.start({
  name = "typescope-oracle",
  cmd = { bin, "--stdio" },
  root_dir = vim.fn.getcwd() .. "/tests/fixtures",
}, { bufnr = bufnr })
check(client_id ~= nil, "vim.lsp.start returned a client id")
local client = client_id and vim.lsp.get_client_by_id(client_id)
vim.wait(20000, function()
  return client and client.initialized
end, 50)
check(client and client.initialized, "client initialized")

if client and client.initialized then
  local info = client.server_info or {}
  check(info.name == "typescope-oracle", "serverInfo.name is typescope-oracle (got " .. tostring(info.name) .. ")")
  check(type(info.version) == "string", "serverInfo.version is a string")
  local caps = client.server_capabilities or {}
  local exp = caps.experimental and caps.experimental.typescope
  check(exp and exp.protocol == 1, "experimental.typescope.protocol == 1")
  -- full sync: nvim normalises the number into a table with change = 1
  local sync = caps.textDocumentSync
  local change = type(sync) == "table" and sync.change or sync
  check(change == 1, "textDocumentSync is Full (got " .. vim.inspect(sync) .. ")")
  for _, forbidden in ipairs({ "hoverProvider", "definitionProvider", "completionProvider", "signatureHelpProvider" }) do
    check(caps[forbidden] == nil, forbidden .. " not advertised")
  end

  -- the class name of the first `class` in shapes.py: a Scope with roots
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local class_line
  for i, l in ipairs(lines) do
    if l:match("^class ServerConfig") then
      class_line = i - 1
      break
    end
  end
  local done, result, err
  client:request("typescope/structure", {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = class_line, character = 6 },
  }, function(e, r)
    done, err, result = true, e, r
  end, bufnr)
  vim.wait(20000, function()
    return done
  end, 10)
  check(done and err == nil, "typescope/structure answered without error (" .. vim.inspect(err) .. ")")
  check(type(result) == "table" and result.scope == "class", "answer is a class Scope (got " .. vim.inspect(result and result.scope) .. ")")
  local root = type(result) == "table" and result.roots and result.roots[1]
  check(root and root.type and root.type.category == "dataclass", "ServerConfig is a dataclass over the wire")
  local names = {}
  for _, c in ipairs(root and root.children or {}) do
    names[#names + 1] = c.name
  end
  check(table.concat(names, ",") == "host,port,debug", "fields host,port,debug (got " .. table.concat(names, ",") .. ")")

  -- a position with nothing under it answers null, not an error
  local done0, result0, err0
  client:request("typescope/structure", {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = 0, character = 0 },
  }, function(e, r)
    done0, err0, result0 = true, e, r
  end, bufnr)
  vim.wait(10000, function()
    return done0
  end, 10)
  check(done0 and err0 == nil and (result0 == nil or result0 == vim.NIL), "nothing under the cursor → null")

  -- an unknown method is refused cleanly, not crashed on
  local done2, err2
  client:request("typescope/nonexistent", {}, function(e)
    done2, err2 = true, e
  end, bufnr)
  vim.wait(5000, function()
    return done2
  end, 10)
  check(done2 and err2 and err2.code == -32601, "unknown request → MethodNotFound")

  client:stop(true)
  vim.wait(2000, function()
    return not vim.lsp.get_client_by_id(client_id)
  end, 50)
  check(vim.lsp.get_client_by_id(client_id) == nil, "shutdown/exit honoured")
end

if failures == 0 then
  print("ALL PASS")
else
  print(("FAILURES: %d"):format(failures))
end
