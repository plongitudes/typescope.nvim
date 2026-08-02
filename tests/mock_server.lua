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

  local function find_by_patterns(word, patterns)
    for _, pat_tpl in ipairs(patterns) do
      local pat = pat_tpl:gsub("WORD", word)
      for _, file in ipairs(files) do
        for lnum, line in ipairs(vim.fn.readfile(file)) do
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

  -- definition mimics basedpyright's runtime-literal answer: a module-level
  -- alias assignment wins over the def it aliases. declaration is the static
  -- answer: class/def sites only (the "stub" universe).
  local function find_definition(word)
    return find_by_patterns(word, { "^WORD%s*=", "^%s*class%s+WORD%f[%W]", "^%s*def%s+WORD%f[%W]" })
  end
  local function find_declaration(word)
    return find_by_patterns(word, { "^%s*class%s+WORD%f[%W]", "^%s*def%s+WORD%f[%W]" })
  end

  -- naive signatureHelp: every single-line def of the word becomes one
  -- signature (overloaded fixtures yield several, like pyright does)
  local function signature_for(word)
    local sigs = {}
    for _, file in ipairs(files) do
      for _, line in ipairs(vim.fn.readfile(file)) do
        if line:match("^%s*def%s+" .. word .. "%s*%(") then
          local inner = line:match("%((.*)%)")
          if inner then
            local params = {}
            for piece in vim.gsplit(inner, ",%s*") do
              if piece ~= "" and piece ~= "self" then
                table.insert(params, { label = piece })
              end
            end
            table.insert(sigs, { label = line:gsub("^%s*def%s*", ""):gsub(":%s*$", ""), parameters = params })
          end
        end
      end
    end
    if #sigs == 0 then
      return nil
    end
    return { signatures = sigs, activeSignature = 0, activeParameter = 0 }
  end

  return function(dispatchers)
    local closing = false
    local srv = {}

    function srv.request(method, params, callback)
      if method == "initialize" then
        callback(nil, {
          capabilities = {
            definitionProvider = true,
            declarationProvider = true,
            signatureHelpProvider = { triggerCharacters = { "(", "," } },
            hoverProvider = true,
            positionEncoding = "utf-16",
          },
        })
      elseif method == "shutdown" then
        callback(nil, nil)
      elseif method == "textDocument/definition" or method == "textDocument/declaration" then
        local fname = vim.uri_to_fname(params.textDocument.uri)
        local word = word_at(fname, params.position.line, params.position.character)
        local finder = method == "textDocument/definition" and find_definition or find_declaration
        callback(nil, word and finder(word) or nil)
      elseif method == "textDocument/signatureHelp" then
        local fname = vim.uri_to_fname(params.textDocument.uri)
        local word = word_at(fname, params.position.line, params.position.character)
        local sig = word and signature_for(word) or nil
        if not sig then
          -- real servers resolve the ENCLOSING call when the cursor sits in
          -- the argument list (the insert-mode surface's position); take the
          -- last `name(` before the cursor as the callee
          -- greedy .* would backtrack the capture down to one char, so
          -- anchor on the last unclosed paren before the cursor instead
          local text = (vim.fn.readfile(fname)[params.position.line + 1] or ""):sub(1, params.position.character)
          local callee = text:match("([%w_]+)%s*%([^()]*$")
          sig = callee and signature_for(callee) or nil
        end
        if sig and #sig.signatures > 1 then
          -- naive arity-based overload selection (real pyright doesn't even
          -- do this — see U4 bead notes — but it lets tests drive the
          -- auto-follow path): each comma before the cursor advances it
          local before = (vim.fn.readfile(fname)[params.position.line + 1] or ""):sub(1, params.position.character)
          local _, commas = before:gsub(",", "")
          sig.activeSignature = math.min(commas, #sig.signatures - 1)
        end
        callback(nil, sig)
      elseif method == "textDocument/hover" then
        local fname = vim.uri_to_fname(params.textDocument.uri)
        local word = word_at(fname, params.position.line, params.position.character)
        if word then
          -- mimic pyright hover shapes: "(type alias) X: rhs" for module-level
          -- alias assignments, "(parameter) x: int" otherwise
          local value
          for _, file in ipairs(files) do
            for _, line in ipairs(vim.fn.readfile(file)) do
              local rhs = line:match("^" .. word .. "%s*=%s*(.+)$")
              if rhs then
                value = ("(type alias) %s: %s"):format(word, rhs)
                break
              end
            end
            if value then
              break
            end
          end
          value = value or ("(parameter) %s: int"):format(word)
          callback(nil, {
            contents = { kind = "markdown", value = "```python\n" .. value .. "\n```" },
          })
        else
          callback(nil, nil)
        end
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
