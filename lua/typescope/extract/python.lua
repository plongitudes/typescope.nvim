-- TreeSitter extraction for Python: function signatures at definition sites,
-- annotation analysis (which names are worth definition-chasing), and field
-- extraction per construct (TypedDict / dataclass / pydantic / NamedTuple /
-- Protocol / plain class).
--
-- `src` everywhere is a bufnr or a raw source string (string form lets tests
-- run on inline snippets with vim.treesitter.get_string_parser).

local M = {}

-- Names never worth chasing: builtins and typing machinery. Anything else
-- (stdlib included) gets a definition request; the typeshed guard in
-- resolve.lua stops recursion into stub files.
local BUILTINS = {}
for _, name in ipairs({
  "str", "int", "float", "bool", "bytes", "bytearray", "complex", "None",
  "list", "dict", "tuple", "set", "frozenset", "type", "object", "memoryview",
  "Any", "AnyStr", "Optional", "Union", "Callable", "Awaitable", "Coroutine",
  "Iterator", "Iterable", "AsyncIterator", "AsyncIterable", "Generator",
  "AsyncGenerator", "Sequence", "Mapping", "MutableMapping", "MutableSequence",
  "List", "Dict", "Tuple", "Set", "FrozenSet", "Type", "Text",
  "Literal", "Annotated", "Final", "ClassVar", "Required", "NotRequired",
  "Self", "TypeVar", "Generic", "Hashable", "Sized", "NoReturn", "Never",
}) do
  BUILTINS[name] = true
end

local function get_root(src)
  local ok, parser
  if type(src) == "number" then
    ok, parser = pcall(vim.treesitter.get_parser, src, "python")
  else
    ok, parser = pcall(vim.treesitter.get_string_parser, src, "python")
  end
  if not ok or not parser then
    return nil
  end
  local trees = parser:parse()
  return trees and trees[1] and trees[1]:root() or nil
end

local function text(node, src)
  return vim.treesitter.get_node_text(node, src)
end

local function clean(s)
  return (s:gsub("%s+", " "))
end

local function walk_up(node, want)
  while node do
    if node:type() == want then
      return node
    end
    node = node:parent()
  end
end

local function field1(node, name)
  return node:field(name)[1]
end

---@return TSNode?
local function node_at(src, row, col)
  local root = get_root(src)
  return root and root:named_descendant_for_range(row, col, row, col) or nil
end

--- Structured signature of the function whose definition contains (row, col).
---@param src integer|string
---@param row integer 0-based
---@param col integer 0-based byte
---@return { name: string, params: table[], return_type: TSNode? }?
function M.function_info(src, row, col)
  local fn = walk_up(node_at(src, row, col), "function_definition")
  if not fn then
    return nil
  end
  local info = {
    name = text(field1(fn, "name"), src),
    params = {},
    return_type = field1(fn, "return_type"),
  }
  local params_node = field1(fn, "parameters")
  if params_node then
    for i = 0, params_node:named_child_count() - 1 do
      local p = params_node:named_child(i)
      local t = p:type()
      local entry
      if t == "identifier" then
        entry = { name = text(p, src) }
      elseif t == "typed_parameter" then
        entry = { name = text(p:named_child(0), src), type_node = field1(p, "type") }
      elseif t == "default_parameter" then
        entry = { name = text(field1(p, "name"), src), default = clean(text(field1(p, "value"), src)) }
      elseif t == "typed_default_parameter" then
        entry = {
          name = text(field1(p, "name"), src),
          type_node = field1(p, "type"),
          default = clean(text(field1(p, "value"), src)),
        }
      elseif t == "list_splat_pattern" or t == "dictionary_splat_pattern" then
        entry = { name = text(p, src) }
      end
      if entry and entry.name ~= "self" and entry.name ~= "cls" then
        table.insert(info.params, entry)
      end
    end
  end
  return info
end

-- typing.X aliases that have modern lowercase builtin forms
local TYPING_LOWER = {
  List = "list",
  Dict = "dict",
  Tuple = "tuple",
  Set = "set",
  FrozenSet = "frozenset",
  Type = "type",
  Deque = "deque",
  DefaultDict = "defaultdict",
}

--- Recursive printer producing the modern normalized form of an annotation:
--- typing.Optional[X] → X | None, typing.Union[A, B] → A | B, List → list,
--- "ForwardRef" → ForwardRef, typing.* prefix stripped. Unknown node kinds
--- fall back to their cleaned source text.
---@param node TSNode
---@param src integer|string
---@return string
local function normalize(node, src)
  local t = node:type()
  if t == "type" then
    local inner = node:named_child(0)
    return inner and normalize(inner, src) or clean(text(node, src))
  end
  if t == "identifier" then
    local name = text(node, src)
    return TYPING_LOWER[name] or name
  end
  if t == "attribute" then
    local obj, attr = field1(node, "object"), field1(node, "attribute")
    if obj and attr and text(obj, src) == "typing" then
      return normalize(attr, src)
    end
    return text(node, src)
  end
  if t == "string" then
    return (text(node, src):gsub("^[\"']", ""):gsub("[\"']$", "")) -- forward ref
  end
  if t == "none" then
    return "None"
  end
  if t == "ellipsis" then
    return "..."
  end
  if t == "binary_operator" then
    local left, right = field1(node, "left"), field1(node, "right")
    if left and right then
      return normalize(left, src) .. " | " .. normalize(right, src)
    end
  end
  if t == "generic_type" or t == "subscript" then
    local head_node, arg_nodes
    if t == "generic_type" then
      head_node = node:named_child(0)
      arg_nodes = {}
      local params = node:named_child(1)
      if params then
        for i = 0, params:named_child_count() - 1 do
          table.insert(arg_nodes, params:named_child(i))
        end
      end
    else
      head_node = field1(node, "value")
      arg_nodes = node:field("subscript")
    end
    if head_node then
      local head = normalize(head_node, src)
      local args = {}
      for _, a in ipairs(arg_nodes) do
        table.insert(args, normalize(a, src))
      end
      if head == "Optional" then
        return (args[1] or "?") .. " | None"
      end
      if head == "Union" then
        return table.concat(args, " | ")
      end
      return head .. "[" .. table.concat(args, ", ") .. "]"
    end
  end
  return clean(text(node, src))
end

--- Analyze an annotation node: display text (normalized to modern syntax) +
--- named user types worth chasing. Positions are where to fire
--- textDocument/definition.
---@param src integer|string
---@param type_node TSNode
---@return { display: string, refs: { name: string, row: integer, col: integer }[] }
function M.annotation(src, type_node)
  local refs, seen = {}, {}
  local function scan(n)
    local t = n:type()
    if t == "identifier" then
      local name = text(n, src)
      if not BUILTINS[name] and not seen[name] then
        seen[name] = true
        local r, c = n:range()
        table.insert(refs, { name = name, row = r, col = c })
      end
      return
    end
    if t == "attribute" then
      -- dotted name like pkg.Config: request at the final identifier
      local attr = field1(n, "attribute")
      if attr then
        local full = text(n, src)
        if not BUILTINS[text(attr, src)] and not seen[full] then
          seen[full] = true
          local r, c = attr:range()
          table.insert(refs, { name = full, row = r, col = c })
        end
      end
      return
    end
    if t == "string" then
      return -- never chase inside Literal["..."] / forward-ref strings (v1)
    end
    for i = 0, n:named_child_count() - 1 do
      scan(n:named_child(i))
    end
  end
  scan(type_node)
  local ok, display = pcall(normalize, type_node, src)
  return { display = ok and display or clean(text(type_node, src)), refs = refs }
end

---@param cls TSNode class_definition
---@return string category, boolean total_false
local function classify(cls, src)
  local category = "class"
  local parent = cls:parent()
  if parent and parent:type() == "decorated_definition" then
    for i = 0, parent:named_child_count() - 1 do
      local d = parent:named_child(i)
      if d:type() == "decorator" then
        local dt = text(d, src)
        if dt:find("pydantic") and dt:find("dataclass") then
          category = "pydantic"
        elseif dt:find("dataclass") then
          category = "dataclass"
        end
      end
    end
  end
  local total_false = false
  local superclasses = field1(cls, "superclasses")
  if superclasses then
    for i = 0, superclasses:named_child_count() - 1 do
      local base = superclasses:named_child(i)
      local bt = base:type()
      if bt == "identifier" or bt == "attribute" then
        local name = text(base, src):match("[%w_]+$")
        if name == "TypedDict" then
          category = "typeddict"
        elseif name == "BaseModel" then
          category = "pydantic"
        elseif name == "NamedTuple" then
          category = "namedtuple"
        elseif name == "Protocol" then
          category = "protocol"
        end
      elseif bt == "keyword_argument" and text(base, src):gsub("%s", "") == "total=False" then
        total_false = true
      end
    end
  end
  return category, total_false
end

--- Field default, unwrapping dataclasses.field(...) / pydantic.Field(...)
--- down to the actual default value.
local function unwrap_default(right, src, category)
  if (category == "pydantic" or category == "dataclass") and right:type() == "call" then
    local fn = field1(right, "function")
    local fname = fn and text(fn, src):match("[%w_]+$")
    if fname == "Field" or fname == "field" then
      local args = field1(right, "arguments")
      if args then
        for i = 0, args:named_child_count() - 1 do
          local arg = args:named_child(i)
          if arg:type() == "keyword_argument" then
            local key = text(field1(arg, "name"), src)
            if key == "default" or key == "default_factory" then
              return clean(text(field1(arg, "value"), src))
            end
          elseif i == 0 then
            return clean(text(arg, src))
          end
        end
      end
      return nil -- Field(...) with no default: field is required
    end
  end
  return clean(text(right, src))
end

--- Protocol method signature as display text, with self stripped.
local function method_signature(fn_node, src)
  local params = field1(fn_node, "parameters")
  local sig = params and clean(text(params, src)) or "()"
  sig = sig:gsub("^%(%s*self%s*,%s*", "("):gsub("^%(%s*self%s*%)", "()")
  local ret = field1(fn_node, "return_type")
  if ret then
    sig = sig .. " -> " .. clean(text(ret, src))
  end
  return sig
end

--- Classify + extract the type whose definition contains (row, col).
--- Second return is "import" when the position landed on an import statement
--- (caller may hop the definition chain once more).
---@param src integer|string
---@param row integer
---@param col integer
---@return table? result, string? marker
function M.type_at(src, row, col)
  local node = node_at(src, row, col)
  if not node then
    return nil
  end
  local cls = walk_up(node, "class_definition")
  if not cls then
    if walk_up(node, "import_from_statement") or walk_up(node, "import_statement") then
      return nil, "import"
    end
    return nil
  end

  local category, total_false = classify(cls, src)
  local result = {
    category = category,
    class_name = text(field1(cls, "name"), src),
    fields = {},
    methods = {},
  }

  local body = field1(cls, "body")
  if not body then
    return result
  end
  for i = 0, body:named_child_count() - 1 do
    local stmt = body:named_child(i)
    if stmt:type() == "expression_statement" then
      local a = stmt:named_child(0)
      if a and a:type() == "assignment" then
        local left, tnode, right = field1(a, "left"), field1(a, "type"), field1(a, "right")
        if left and left:type() == "identifier" and tnode then
          local fname = text(left, src)
          if not fname:match("^__") then
            local badge
            local inner = tnode
            -- Required[X]/NotRequired[X]: annotation grammar produces
            -- generic_type in current tree-sitter-python; older versions
            -- used subscript — accept both
            local wrapper = tnode:named_child(0)
            local wt = wrapper and wrapper:type()
            if wt == "generic_type" or wt == "subscript" then
              local value = field1(wrapper, "value") or wrapper:named_child(0)
              local vname = value and text(value, src)
              if vname == "Required" or vname == "NotRequired" then
                badge = vname
                if wt == "subscript" then
                  inner = field1(wrapper, "subscript") or tnode
                else
                  local tp = wrapper:named_child(1) -- type_parameter
                  inner = (tp and tp:named_child(0)) or tnode
                end
              end
            end
            if category == "typeddict" and not badge and total_false then
              badge = "NotRequired"
            end
            table.insert(result.fields, {
              name = fname,
              type_node = inner,
              default = right and unwrap_default(right, src, category) or nil,
              badge = badge,
            })
          end
        end
      end
    elseif stmt:type() == "function_definition" and category == "protocol" then
      local mname = text(field1(stmt, "name"), src)
      if not mname:match("^__") then
        table.insert(result.methods, { name = mname, signature = method_signature(stmt, src) })
      end
    end
  end
  return result
end

return M
