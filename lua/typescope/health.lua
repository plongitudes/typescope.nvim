local M = {}

local health = vim.health

function M.check()
  health.start("typescope.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim >= 0.10")
  else
    health.error("Neovim 0.10+ required")
  end

  -- python treesitter parser (required for type definition extraction)
  -- language.add errors on 0.10 but returns false on 0.11+ — check both
  local ok, added = pcall(vim.treesitter.language.add, "python")
  local has_parser = ok and added ~= false
  if has_parser then
    health.ok("TreeSitter python parser installed")
  else
    health.error("TreeSitter python parser not found", { "Install with nvim-treesitter: :TSInstall python" })
  end

  -- basedpyright (required for type inference)
  local clients = vim.lsp.get_clients({ name = "basedpyright" })
  if #clients > 0 then
    health.ok("basedpyright client active")
  elseif vim.fn.executable("basedpyright-langserver") == 1 then
    health.ok("basedpyright-langserver executable found (no active client in this session)")
  else
    health.warn(
      "basedpyright not found",
      { "TypeScope requires basedpyright for type resolution", "Install: pip install basedpyright" }
    )
  end

  local cfg = require("typescope.config").get()

  health.start("typescope.nvim: examples (optional)")
  if not cfg.ollama.enabled then
    health.ok("Ollama disabled (heuristic examples only)")
    return
  end

  if vim.fn.executable("curl") ~= 1 then
    health.error("curl not found", { "LLM example generation requires curl" })
    return
  end
  health.ok("curl found")

  local url = ("http://%s:%d/api/version"):format(cfg.ollama.host, cfg.ollama.port)
  local result = vim.system({ "curl", "-sf", "--max-time", "2", url }, { text = true }):wait()
  if result.code == 0 then
    health.ok(("Ollama reachable at %s:%d"):format(cfg.ollama.host, cfg.ollama.port))
  else
    health.warn(
      ("Ollama unreachable at %s:%d"):format(cfg.ollama.host, cfg.ollama.port),
      { "LLM examples will fall back to heuristics", "Start with: ollama serve" }
    )
  end
end

return M
