-- Awaitable LSP request helpers + 0.10/0.11 compat shims.
--
-- Requests go through a captured client object (client.request), NOT
-- vim.lsp.buf.* : definition requests are fired at positions inside type
-- definition files the user never opened, and those buffers have no attached
-- client. Servers (basedpyright included) resolve unopened files from disk.

local async = require("typescope.async")

local M = {}

local has_011 = vim.fn.has("nvim-0.11") == 1

--- First client attached to bufnr that can serve textDocument/definition.
---@param bufnr integer
---@return vim.lsp.Client?
function M.client_for(bufnr)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    local ok, supported
    if has_011 then
      ok, supported = pcall(function()
        return client:supports_method("textDocument/definition")
      end)
    else
      ok, supported = pcall(client.supports_method, "textDocument/definition")
    end
    if ok and supported then
      return client
    end
  end
end

-- vim.str_utfindex/str_byteindex changed signatures between 0.10 and 0.11.
---@param line string
---@param byte_col integer
---@return integer utf-16 column
function M.to_utf16(line, byte_col)
  byte_col = math.min(byte_col, #line)
  if byte_col <= 0 then
    return 0
  end
  if has_011 then
    return vim.str_utfindex(line, "utf-16", byte_col, false)
  end
  local _, utf16 = vim.str_utfindex(line, byte_col)
  return utf16
end

---@param line string
---@param utf16_col integer
---@return integer byte column
function M.to_byte(line, utf16_col)
  if utf16_col <= 0 then
    return 0
  end
  local ok, byte_col
  if has_011 then
    ok, byte_col = pcall(vim.str_byteindex, line, "utf-16", utf16_col, false)
  else
    ok, byte_col = pcall(vim.str_byteindex, line, utf16_col, true)
  end
  return ok and byte_col or math.min(utf16_col, #line)
end

local function get_line(bufnr, row)
  return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

--- Await one request on one client. Returns nil on error or cancellation.
--- Must be called inside async.run.
---@param client vim.lsp.Client
---@param method string
---@param params table
---@param token typescope.CancelToken
---@return any? result
function M.request(client, method, params, token)
  local err, result = async.await(function(resume)
    local done = false
    local function finish(e, r)
      if not done then
        done = true
        resume(e, r)
      end
    end
    local handler = function(e, r)
      finish(e, r)
    end
    local ok, request_id
    if has_011 then
      ok, request_id = client:request(method, params, handler)
    else
      ok, request_id = client.request(method, params, handler)
    end
    if not ok then
      finish("request failed")
      return
    end
    table.insert(token.cancels, function()
      if request_id then
        if has_011 then
          pcall(function()
            client:cancel_request(request_id)
          end)
        else
          pcall(client.cancel_request, request_id)
        end
      end
      finish("cancelled")
    end)
  end)
  if err then
    return nil
  end
  return result
end

--- Normalize a definition response (Location | Location[] | LocationLink[])
--- to a single { uri, range }.
---@param result any
---@return { uri: string, range: table }?
function M.first_location(result)
  if not result then
    return nil
  end
  if result.uri or result.targetUri then
    result = { result }
  end
  local loc = result[1]
  if not loc then
    return nil
  end
  if loc.targetUri then
    return { uri = loc.targetUri, range = loc.targetSelectionRange or loc.targetRange }
  end
  return { uri = loc.uri, range = loc.range }
end

--- Location request (definition/declaration/typeDefinition) at a 0-based
--- (row, byte-col) in bufnr.
---@param client vim.lsp.Client
---@param bufnr integer
---@param row integer
---@param col integer byte column
---@param token typescope.CancelToken
---@param method? string defaults to textDocument/definition
---@return { uri: string, range: table }?
function M.locate(client, bufnr, row, col, token, method)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = row, character = M.to_utf16(get_line(bufnr, row), col) },
  }
  return M.first_location(M.request(client, method or "textDocument/definition", params, token))
end

--- textDocument/definition shorthand (the pipeline's workhorse).
function M.definition(client, bufnr, row, col, token)
  return M.locate(client, bufnr, row, col, token, "textDocument/definition")
end

--- textDocument/signatureHelp at the window's cursor. Used for the anchor
--- float content and the activeParameter index.
---@param client vim.lsp.Client
---@param bufnr integer
---@param win integer
---@param token typescope.CancelToken
---@return table? signatureHelp result
function M.signature_help(client, bufnr, win, token)
  local pos = vim.api.nvim_win_get_cursor(win)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = pos[1] - 1, character = M.to_utf16(get_line(bufnr, pos[1] - 1), pos[2]) },
  }
  local result = M.request(client, "textDocument/signatureHelp", params, token)
  if result and result.signatures and #result.signatures > 0 then
    return result
  end
  return nil
end

--- Signature-help result rendered to markdown lines for the anchor float.
---@param result table signatureHelp result
---@param ft string
---@return string[]?
function M.signature_markdown(result, ft)
  local lines = vim.lsp.util.convert_signature_help_to_markdown_lines(result, ft, nil)
  return lines and #lines > 0 and lines or nil
end

--- Hover contents as markdown lines — the anchor fallback when signatureHelp
--- is empty (servers only answer it with the cursor inside the call parens;
--- hover answers anywhere on the symbol).
---@param client vim.lsp.Client
---@param bufnr integer
---@param win integer
---@param token typescope.CancelToken
---@return string[]?
function M.hover_markdown(client, bufnr, win, token)
  local pos = vim.api.nvim_win_get_cursor(win)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = pos[1] - 1, character = M.to_utf16(get_line(bufnr, pos[1] - 1), pos[2]) },
  }
  local result = M.request(client, "textDocument/hover", params, token)
  if not result or not result.contents then
    return nil
  end
  local lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
  while lines[#lines] == "" do
    table.remove(lines)
  end
  return #lines > 0 and lines or nil
end

--- Index (0-based) of the active parameter, or nil.
---@param result table? signatureHelp result
---@return integer?
function M.active_param(result)
  if not result then
    return nil
  end
  local sig = result.signatures[(result.activeSignature or 0) + 1]
  if not sig then
    return nil
  end
  return sig.activeParameter or result.activeParameter
end

--- Load (without displaying) the buffer for a uri. We only ever parse these
--- buffers, so a stale/foreign swapfile always resolves to open-readonly
--- instead of throwing E325 (which aborts the whole pipeline).
---@param uri string
---@return integer bufnr
function M.load_buf(uri)
  local bufnr = vim.uri_to_bufnr(uri)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    local group = vim.api.nvim_create_augroup("TypeScopeSwapExists", { clear = true })
    vim.api.nvim_create_autocmd("SwapExists", {
      group = group,
      callback = function()
        vim.v.swapchoice = "o"
      end,
    })
    pcall(vim.fn.bufload, bufnr)
    vim.api.nvim_del_augroup_by_id(group)
  end
  return bufnr
end

--- LSP range start as 0-based (row, byte-col) in the loaded buffer.
---@param bufnr integer
---@param range table
---@return integer row, integer col
function M.range_start(bufnr, range)
  local row = range.start.line
  return row, M.to_byte(get_line(bufnr, row), range.start.character)
end

return M
