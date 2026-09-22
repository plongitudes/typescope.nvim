-- The oracle client: start `typescope-oracle` as a second language server on
-- Python buffers, find it again per buffer, and ask it `typescope/structure`.
-- design/oracle.md §3 and §5.
--
-- The oracle advertises nothing but document sync plus its one custom
-- request, so it never competes with basedpyright; nvim's own client does
-- the spawning, the didOpen/didChange of unsaved contents, and the lifetime.
-- Locating the binary is `locate()`; when nothing is found and
-- `oracle.download` is on, `download()` fetches this plugin's release build
-- for the platform into stdpath("data") and verifies it against the
-- release's SHA256SUMS before it is ever executed (decision 2).

local M = {}

local has_011 = vim.fn.has("nvim-0.11") == 1

--- The protocol number this plugin speaks; the binary reports its own in
--- `experimental.typescope.protocol` and a mismatch refuses to attach.
M.PROTOCOL = 1

M.CLIENT_NAME = "typescope-oracle"
M.STRUCTURE = "typescope/structure"

--- The release whose binary this plugin version downloads. Bumped with the
--- plugin; the oracle and the plugin are released together.
M.RELEASE = "v0.2.0"
--- Where releases live. Overridable for tests (a local server) through
--- `oracle.release_url`; users never set it.
M.RELEASE_URL = "https://github.com/plongitudes/typescope.nvim/releases/download"

--- Recorded protocol mismatch, for :checkhealth. nil when none seen.
---@type { got: any, want: integer, version: string? }?
M.mismatch = nil
--- The last download failure, for :checkhealth.
---@type string?
M.download_error = nil

local group = nil
local warned_missing = false

--- The plugin's own checkout, for the dev-build fallback.
local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h:h:h")
end

--- Where the binary is, in order of intent: the user's explicit path, the
--- downloaded one under stdpath("data"), then a build in this checkout
--- (development). nil when none is executable.
---@param cfg? typescope.Config
---@return string? path
function M.locate(cfg)
  cfg = cfg or require("typescope.config").get()
  local candidates = {}
  if cfg.oracle.path and cfg.oracle.path ~= "" then
    table.insert(candidates, vim.fn.expand(cfg.oracle.path))
  end
  table.insert(candidates, vim.fn.stdpath("data") .. "/typescope/typescope-oracle")
  local root = plugin_root()
  table.insert(candidates, root .. "/oracle/target/release/typescope-oracle")
  table.insert(candidates, root .. "/oracle/target/debug/typescope-oracle")
  for _, path in ipairs(candidates) do
    if vim.fn.executable(path) == 1 then
      return path
    end
  end
  return nil
end

--- The downloaded binary's home. One file per plugin install; a new release
--- overwrites it.
---@return string dir, string path
function M.install_path()
  local dir = vim.fn.stdpath("data") .. "/typescope"
  return dir, dir .. "/typescope-oracle"
end

--- The release asset name for this machine, or nil (and why) when there is
--- no build for it.
---@return string? target, string? why
function M.target()
  local u = vim.uv.os_uname()
  local os = ({ Darwin = "darwin", Linux = "linux" })[u.sysname]
  local arch = ({ arm64 = "arm64", aarch64 = "arm64", x86_64 = "x86_64", amd64 = "x86_64" })[u.machine]
  if not os or not arch then
    return nil, ("no release build for %s/%s"):format(u.sysname, u.machine)
  end
  return os .. "-" .. arch
end

--- Does `path`'s content hash to the entry for `name` in a SHA256SUMS file?
--- Pure: the sums text is passed in.
---@param path string
---@param sums string SHA256SUMS contents (`<hex>  <name>` lines)
---@param name string asset name
---@return boolean ok, string why
function M.verify(path, sums, name)
  local want
  for line in sums:gmatch("[^\n]+") do
    local hex, file = line:match("^(%x+)%s+%*?(%S+)$")
    if hex and file == name then
      want = hex:lower()
    end
  end
  if not want then
    return false, "no SHA256SUMS entry for " .. name
  end
  local f = io.open(path, "rb")
  if not f then
    return false, "cannot read " .. path
  end
  local data = f:read("a")
  f:close()
  local got = vim.fn.sha256(data)
  if got ~= want then
    return false, ("checksum mismatch for %s: got %s, release says %s"):format(name, got:sub(1, 12), want:sub(1, 12))
  end
  return true, "ok"
end

local downloading = false

--- Fetch the release binary for this platform, verify it, install it, and
--- call back with (path) or (nil, why). Never runs the binary before the
--- checksum matches. One download at a time; a second call while one is in
--- flight reports so and does nothing.
---@param cfg? typescope.Config
---@param cb fun(path: string?, why: string?)
function M.download(cfg, cb)
  cfg = cfg or require("typescope.config").get()
  if downloading then
    return cb(nil, "download already in progress")
  end
  local target, why = M.target()
  if not target then
    return cb(nil, why)
  end
  if vim.fn.executable("curl") ~= 1 then
    return cb(nil, "curl not found (needed to download the oracle; or set oracle.path)")
  end
  local base = (cfg.oracle.release_url or M.RELEASE_URL) .. "/" .. M.RELEASE
  local name = "typescope-oracle-" .. target
  local dir, final = M.install_path()
  vim.fn.mkdir(dir, "p")
  local tmp = final .. ".download"
  downloading = true
  local function finish(path, reason)
    downloading = false
    cb(path, reason)
  end
  -- SHA256SUMS first: a release without one is refused outright
  vim.system({ "curl", "-fsSL", "--max-time", "30", base .. "/SHA256SUMS" }, { text = true }, function(sums)
    vim.schedule(function()
      if sums.code ~= 0 or not sums.stdout or sums.stdout == "" then
        return finish(nil, ("could not fetch %s/SHA256SUMS (curl exit %d)"):format(base, sums.code))
      end
      vim.system({ "curl", "-fsSL", "--max-time", "300", "-o", tmp, base .. "/" .. name }, {}, function(bin)
        vim.schedule(function()
          if bin.code ~= 0 then
            pcall(vim.uv.fs_unlink, tmp)
            return finish(nil, ("could not fetch %s/%s (curl exit %d)"):format(base, name, bin.code))
          end
          local ok, reason = M.verify(tmp, sums.stdout, name)
          if not ok then
            pcall(vim.uv.fs_unlink, tmp)
            return finish(nil, reason)
          end
          vim.uv.fs_chmod(tmp, 493) -- 0755
          local renamed = vim.uv.fs_rename(tmp, final)
          if not renamed then
            pcall(vim.uv.fs_unlink, tmp)
            return finish(nil, "could not install " .. final)
          end
          finish(final)
        end)
      end)
    end)
  end)
end

--- `typescope-oracle --version` output, e.g.
--- "typescope-oracle 0.2.0 (protocol 1, pyrefly 1.4.0-dev.1)"; nil when the
--- binary is missing or does not answer.
---@param path? string
---@return string?
function M.version(path)
  path = path or M.locate()
  if not path then
    return nil
  end
  local ok, result = pcall(function()
    return vim.system({ path, "--version" }, { text = true }):wait(5000)
  end)
  if not ok or not result or result.code ~= 0 then
    return nil
  end
  return vim.trim(result.stdout or "")
end

--- Does an initialize result speak our protocol? Pure, for tests.
---@param capabilities table server_capabilities
---@return boolean ok, any got
function M.protocol_ok(capabilities)
  local got = vim.tbl_get(capabilities or {}, "experimental", "typescope", "protocol")
  return got == M.PROTOCOL, got
end

local function stop(client)
  if has_011 then
    pcall(function()
      client:stop(true)
    end)
  else
    pcall(vim.lsp.stop_client, client.id, true)
  end
end

--- Attach the oracle to a Python buffer (idempotent: vim.lsp.start reuses a
--- client with the same name and root).
---@param bufnr integer
---@param cfg? typescope.Config
---@return integer? client_id
function M.attach(bufnr, cfg)
  cfg = cfg or require("typescope.config").get()
  local bin = M.locate(cfg)
  if not bin then
    if cfg.oracle.download then
      -- fetch once, then attach every open Python buffer; a failure is
      -- reported once and health says what to do
      if not warned_missing then
        warned_missing = true
        M.download(cfg, function(path, why)
          if path then
            vim.notify("typescope: oracle " .. M.RELEASE .. " installed at " .. path, vim.log.levels.INFO)
            for _, b in ipairs(vim.api.nvim_list_bufs()) do
              if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "python" then
                M.attach(b, cfg)
              end
            end
          else
            M.download_error = why
            vim.notify(
              "typescope: could not download the oracle — " .. why .. " (see :checkhealth typescope)",
              vim.log.levels.WARN
            )
          end
        end)
      end
    elseif not warned_missing then
      warned_missing = true
      vim.notify(
        "typescope: oracle binary not found and oracle.download is off — see :checkhealth typescope",
        vim.log.levels.WARN
      )
    end
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local root = vim.fs.root(
    name ~= "" and name or bufnr,
    { "pyrefly.toml", "pyproject.toml", "pyrightconfig.json", ".git" }
  ) or vim.fn.getcwd()
  return vim.lsp.start({
    name = M.CLIENT_NAME,
    cmd = { bin, "--stdio" },
    root_dir = root,
    on_init = function(client, init_result)
      local ok, got = M.protocol_ok(init_result and init_result.capabilities or client.server_capabilities)
      if not ok then
        local info = init_result and init_result.serverInfo or {}
        M.mismatch = { got = got, want = M.PROTOCOL, version = info.version }
        vim.notify(
          ("typescope: oracle speaks protocol %s, this plugin needs %d — see :checkhealth typescope"):format(
            tostring(got),
            M.PROTOCOL
          ),
          vim.log.levels.ERROR
        )
        stop(client)
      end
    end,
  }, { bufnr = bufnr })
end

--- The oracle client attached to a buffer (or, with no buffer, any live
--- oracle client), nil when none.
---@param bufnr? integer
---@return vim.lsp.Client?
function M.client_for(bufnr)
  local filter = { name = M.CLIENT_NAME }
  if bufnr then
    filter.bufnr = bufnr
  end
  local clients = vim.lsp.get_clients(filter)
  return clients[1]
end

--- Ask `typescope/structure`. cb(err, scope) — scope is nil for "nothing
--- under the cursor" (K's job) and a Scope table otherwise (design/oracle.md §4).
---@param bufnr integer
---@param params { position: { line: integer, character: integer }, depth?: integer, members?: "data"|"all", call?: boolean }
---@param token typescope.CancelToken
---@param cb fun(err: any, scope: table?)
function M.request(bufnr, params, token, cb)
  local client = M.client_for(bufnr)
  if not client then
    return cb("typescope: no oracle client attached to this buffer")
  end
  params.textDocument = { uri = vim.uri_from_bufnr(bufnr) }
  require("typescope.lsp").request_cb(client, M.STRUCTURE, params, token, function(err, result)
    if result == vim.NIL then
      result = nil
    end
    cb(err, result)
  end)
end

--- Wire the FileType autocmd (and sweep buffers that are already open).
--- Called from setup(); calling it again re-creates the group cleanly.
---@param cfg typescope.Config
function M.enable(cfg)
  group = vim.api.nvim_create_augroup("TypeScopeOracle", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "python",
    desc = "TypeScope: attach the type oracle",
    callback = function(args)
      M.attach(args.buf, cfg)
    end,
  })
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "python" then
      M.attach(bufnr, cfg)
    end
  end
end

return M
