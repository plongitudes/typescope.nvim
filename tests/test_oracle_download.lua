-- The release download (design/oracle.md decision 2), against a LOCAL release
-- server: a directory with `typescope-oracle-<target>` and SHA256SUMS served
-- by python's http.server. Proves the happy path installs an executable that
-- answers --version, a wrong checksum is refused and nothing is installed, a
-- missing SHA256SUMS is refused, and target()/verify() are what they claim.
-- No network beyond localhost.
--
-- Needs a built binary to serve; skips itself otherwise.
local root = vim.fn.getcwd()
local bin = vim.env.TYPESCOPE_ORACLE or (root .. "/oracle/target/debug/typescope-oracle")
if vim.fn.executable(bin) ~= 1 or vim.fn.executable("python3") ~= 1 or vim.fn.executable("curl") ~= 1 then
  print("SKIP test_oracle_download: needs a built oracle, python3 and curl")
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

-- a throwaway data dir so the real one is never touched
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/data", "p")
local real_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(what)
  if what == "data" then
    return tmp .. "/data"
  end
  return real_stdpath(what)
end

-- pure parts
local target = oracle.target()
check(
  target == "darwin-arm64" or target == "darwin-x86_64" or target == "linux-x86_64" or target == "linux-arm64",
  "target(): " .. tostring(target)
)
local dir, final = oracle.install_path()
check(final == tmp .. "/data/typescope/typescope-oracle", "install_path() is under stdpath('data')")

local sums_of = function(path, name)
  local f = assert(io.open(path, "rb"))
  local data = f:read("a")
  f:close()
  return vim.fn.sha256(data) .. "  " .. name .. "\n"
end
local name = "typescope-oracle-" .. target
check(oracle.verify(bin, sums_of(bin, name), name) == true, "verify() accepts a matching SHA256SUMS line")
check(oracle.verify(bin, ("0"):rep(64) .. "  " .. name .. "\n", name) == false, "verify() rejects a wrong hash")
check(oracle.verify(bin, sums_of(bin, "other-asset"), name) == false, "verify() rejects a missing entry")

-- a local "release": <release>/<RELEASE>/{asset, SHA256SUMS}
local site = tmp .. "/site/" .. oracle.RELEASE
vim.fn.mkdir(site, "p")
vim.fn.system({ "cp", bin, site .. "/" .. name })
vim.fn.writefile({ (sums_of(bin, name):gsub("\n$", "")) }, site .. "/SHA256SUMS")
local port = 18732 + math.random(0, 200)
local server = vim.system(
  { "python3", "-m", "http.server", tostring(port), "--bind", "127.0.0.1", "--directory", tmp .. "/site" },
  {}
)
vim.wait(3000, function()
  return vim.system({ "curl", "-fs", ("http://127.0.0.1:%d/%s/SHA256SUMS"):format(port, oracle.RELEASE) }):wait().code
    == 0
end, 100)
local base = ("http://127.0.0.1:%d"):format(port)
local cfg = require("typescope.config").setup({ oracle = { download = true, release_url = base } })

-- happy path
local done, got_path, got_why
oracle.download(cfg, function(p, why)
  done, got_path, got_why = true, p, why
end)
vim.wait(30000, function()
  return done
end, 50)
check(done and got_path == final, "download installs at install_path() (" .. tostring(got_why) .. ")")
check(vim.fn.executable(final) == 1, "installed binary is executable")
check((oracle.version(final) or ""):match("^typescope%-oracle") ~= nil, "installed binary answers --version")
check(vim.fn.filereadable(final .. ".download") == 0, "no temp file left behind")
check(oracle.locate(cfg) == final, "locate() now finds the downloaded binary")

-- tampered checksum: refused, nothing installed
vim.fn.delete(final)
vim.fn.writefile({ ("0"):rep(64) .. "  " .. name }, site .. "/SHA256SUMS")
done = false
oracle.download(cfg, function(p, why)
  done, got_path, got_why = true, p, why
end)
vim.wait(30000, function()
  return done
end, 50)
check(
  done and got_path == nil and (got_why or ""):find("checksum mismatch", 1, true) ~= nil,
  "wrong checksum is refused (" .. tostring(got_why) .. ")"
)
check(
  vim.fn.filereadable(final) == 0 and vim.fn.filereadable(final .. ".download") == 0,
  "nothing installed after a refusal"
)

-- no SHA256SUMS at all: refused before fetching the binary
vim.fn.delete(site .. "/SHA256SUMS")
done = false
oracle.download(cfg, function(p, why)
  done, got_path, got_why = true, p, why
end)
vim.wait(30000, function()
  return done
end, 50)
check(
  done and got_path == nil and (got_why or ""):find("SHA256SUMS", 1, true) ~= nil,
  "missing SHA256SUMS is refused (" .. tostring(got_why) .. ")"
)

-- opt-out is a config value attach() consults before ever calling download();
-- attach() itself is exercised by test_oracle_client.lua with a binary present
vim.fn.delete(final)
local off = require("typescope.config").setup({ oracle = { download = false, release_url = base } })
check(off.oracle.download == false, "download can be turned off")

server:kill(15)
vim.fn.stdpath = real_stdpath
vim.fn.delete(tmp, "rf")

if failures == 0 then
  print("ALL PASS")
else
  print(("FAILURES: %d"):format(failures))
end
