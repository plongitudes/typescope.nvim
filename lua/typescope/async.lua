---@class typescope.CancelToken
---@field generation integer
---@field cancelled boolean
---@field cancels fun()[] cleanup hooks (e.g. LSP $/cancelRequest) run on cancel

local M = {}

local generation = 0

--- New token for one pipeline run. Creating a token stales every older one,
--- so a fresh trigger implicitly abandons in-flight work.
---@return typescope.CancelToken
function M.token()
  generation = generation + 1
  return { generation = generation, cancelled = false, cancels = {} }
end

---@param token typescope.CancelToken
---@return boolean
function M.stale(token)
  return token.cancelled or token.generation ~= generation
end

---@param token typescope.CancelToken
function M.cancel(token)
  if token.cancelled then
    return
  end
  token.cancelled = true
  for _, fn in ipairs(token.cancels) do
    pcall(fn)
  end
end

--- Run fn inside a coroutine so it can use M.await.
---@param fn fun()
function M.run(fn)
  local co = coroutine.create(fn)
  local ok, err = coroutine.resume(co)
  if not ok then
    vim.schedule(function()
      vim.notify("typescope: " .. tostring(err), vim.log.levels.ERROR)
    end)
  end
end

--- Suspend the current coroutine until `thunk`'s callback fires. Handles the
--- callback firing synchronously (before we ever yield) as well as async.
--- The callback must be invoked at most once from the main loop.
---@param thunk fun(resume: fun(...))
---@return ... whatever the callback was called with
function M.await(thunk)
  local co = assert(coroutine.running(), "typescope.async.await outside coroutine")
  local yielded = false
  local sync_result = nil
  local fired = false
  thunk(function(...)
    if fired then
      return
    end
    fired = true
    if yielded then
      local ok, err = coroutine.resume(co, ...)
      if not ok then
        vim.schedule(function()
          vim.notify("typescope: " .. tostring(err), vim.log.levels.ERROR)
        end)
      end
    else
      sync_result = { n = select("#", ...), ... }
    end
  end)
  if sync_result then
    return unpack(sync_result, 1, sync_result.n)
  end
  yielded = true
  return coroutine.yield()
end

return M
