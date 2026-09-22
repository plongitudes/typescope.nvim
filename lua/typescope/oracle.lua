-- The oracle client: start `typescope-oracle` as a second language server on
-- Python buffers, find it again per buffer, and ask it `typescope/structure`.
-- design/oracle.md §3 and §5.
--
-- The oracle advertises nothing but document sync plus its one custom
-- request, so it never competes with basedpyright; nvim's own client does
-- the spawning, the didOpen/didChange of unsaved contents, and the lifetime.
-- Locating the binary is `locate()`; downloading one (decision 2) is a later
-- bead and slots in ahead of the dev-build fallback there.

local M = {}

local has_011 = vim.fn.has("nvim-0.11") == 1

--- The protocol number this plugin speaks; the binary reports its own in
--- `experimental.typescope.protocol` and a mismatch refuses to attach.
M.PROTOCOL = 1

M.CLIENT_NAME = "typescope-oracle"
M.STRUCTURE = "typescope/structure"

--- Recorded protocol mismatch, for :checkhealth. nil when none seen.
---@type { got: any, want: integer, version: string? }?
M.mismatch = nil

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
    if not warned_missing then
      warned_missing = true
      vim.notify("typescope: oracle binary not found — see :checkhealth typescope", vim.log.levels.WARN)
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
