-- In-process mock LSP server for tests: serves textDocument/definition by
-- grepping fixture files for `class X` / `def X` definitions. The client-side
-- path (client.request, handlers, uri plumbing) is identical to production —
-- only the server side is fake.

local M = {}

---@param fixture_dir string absolute path containing .py fixtures
---@return fun(dispatchers: table): table cmd for vim.lsp.start
function M.cmd(fixture_dir)
  local files = vim.fn.glob(fixture_dir .. "/*.py", false, true)

  local function word_at(fname, line, character)
    local text = (vim.fn.readfile(fname)[line + 1]) or ""
    -- find the identifier covering `character` (fixtures are ASCII: byte == utf-16)
    local init = 1
    while true do
      local s, e = text:find("[%w_]+", init)
      if not s then
        return nil
      end
      if s - 1 <= character and character < e then
        return text:sub(s, e)
      end
      init = e + 1
    end
  end

  local function find_definition(word)
    for _, file in ipairs(files) do
      for lnum, line in ipairs(vim.fn.readfile(file)) do
        for _, pat in ipairs({ "^%s*class%s+(" .. word .. ")%f[%W]", "^%s*def%s+(" .. word .. ")%f[%W]" }) do
          if line:match(pat) then
            local col = line:find(word, 1, true) - 1
            return {
              uri = vim.uri_from_fname(file),
              range = {
                start = { line = lnum - 1, character = col },
                ["end"] = { line = lnum - 1, character = col + #word },
              },
            }
          end
        end
      end
    end
  end

  return function(dispatchers)
    local closing = false
    local srv = {}

    function srv.request(method, params, callback)
      if method == "initialize" then
        callback(nil, {
          capabilities = { definitionProvider = true, positionEncoding = "utf-16" },
        })
      elseif method == "shutdown" then
        callback(nil, nil)
      elseif method == "textDocument/definition" then
        local fname = vim.uri_to_fname(params.textDocument.uri)
        local word = word_at(fname, params.position.line, params.position.character)
        callback(nil, word and find_definition(word) or nil)
      else
        callback(nil, nil)
      end
      return true, 1
    end

    function srv.notify(method, _)
      if method == "exit" then
        closing = true
        if dispatchers.on_exit then
          dispatchers.on_exit(0, 0)
        end
      end
      return true
    end

    function srv.is_closing()
      return closing
    end

    function srv.terminate()
      closing = true
    end

    return srv
  end
end

return M
