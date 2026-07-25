-- Language registry: the extension point for future non-Python support.
-- An impl must provide:
--   function_info(src, row, col) -> { name, params = {{name, type_node?, default?}}, return_type? }
--   annotation(src, type_node)   -> { display, refs = {{name, row, col}} }
--   type_at(src, row, col)       -> { category, class_name, fields, methods }?, marker?
-- where src is a bufnr or a source string (string form used by tests).

local M = {}

local impls = {}

---@param lang string
---@param impl table
function M.register(lang, impl)
  impls[lang] = impl
end

---@param lang string
---@return table?
function M.get(lang)
  if not impls[lang] then
    local ok, impl = pcall(require, "typescope.extract." .. lang)
    if ok then
      impls[lang] = impl
    end
  end
  return impls[lang]
end

return M
