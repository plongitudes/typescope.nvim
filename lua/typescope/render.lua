---@class typescope.Highlight
---@field line integer 0-indexed
---@field col_start integer byte offset
---@field col_end integer byte offset
---@field group string

---@class typescope.RenderResult
---@field lines string[]
---@field highlights typescope.Highlight[]
---@field line_to_node table<integer, string> 1-indexed line -> node id (continuation lines included)
---@field width integer display width of the widest line

---@class typescope.RenderOpts
---@field style typescope.Charset
---@field max_width integer
---@field show_examples boolean
---@field example_kind "heuristic"|"llm"

local M = {}

local strwidth = vim.api.nvim_strwidth

-- Accumulates (text, group) segments for one visual line, tracking byte
-- offsets for extmark highlights and display width for wrapping.
local Line = {}
Line.__index = Line

local function new_line()
  return setmetatable({ text = "", width = 0, hls = {} }, Line)
end

---@param text string
---@param group? string
function Line:add(text, group)
  if text == "" then
    return self
  end
  if group then
    table.insert(self.hls, { col_start = #self.text, col_end = #self.text + #text, group = group })
  end
  self.text = self.text .. text
  self.width = self.width + strwidth(text)
  return self
end

--- Decide where to break annotation text that exceeds the available width.
--- Returns the byte index (1-based, inclusive) of the last character to keep
--- on the current line. `limit` is the max number of display cells available.
---
--- TODO(user): this is the wrap-point heuristic — currently a hard cut at the
--- limit. A smarter version prefers breaking after ", " or an opening bracket
--- so wrapped generics like dict[str, Callable[[Request, Session], ...]] split
--- at readable points. See the spike output to judge what reads best.
---@param text string annotation text (assumed single-width chars)
---@param limit integer display cells available on this line
---@return integer
local function find_break_point(text, limit)
  return limit
end

---@param node typescope.Node
---@return boolean
local function is_expandable(node)
  return #node.children > 0 or (not node.state.loaded and node.source ~= nil)
end

---@param node typescope.Node
---@param opts typescope.RenderOpts
---@return string?
local function example_for(node, opts)
  if not opts.show_examples then
    return nil
  end
  return node.example[opts.example_kind] or node.example.heuristic
end

--- Render a forest of nodes into lines + highlights. Pure: no window or
--- buffer API calls, so the spike and tests exercise production rendering.
---@param roots typescope.Node[]
---@param opts typescope.RenderOpts
---@return typescope.RenderResult
function M.render(roots, opts)
  local style = opts.style
  local result = { lines = {}, highlights = {}, line_to_node = {}, width = 0 }

  local function emit(line, node_id)
    table.insert(result.lines, line.text)
    local lnum = #result.lines
    result.line_to_node[lnum] = node_id
    for _, hl in ipairs(line.hls) do
      table.insert(result.highlights, {
        line = lnum - 1,
        col_start = hl.col_start,
        col_end = hl.col_end,
        group = hl.group,
      })
    end
    result.width = math.max(result.width, line.width)
  end

  -- Wrap the tail segments (type/default/example) of a row across
  -- continuation lines with a hanging indent at the annotation column.
  ---@param line typescope.Line current line holding prefix + name padding
  ---@param cont_prefix string chrome carried onto continuation lines
  ---@param cont_pad integer spaces after cont_prefix to reach the annotation column
  ---@param segments { [1]: string, [2]: string? }[] tail segments (text, group)
  ---@param node_id string
  local function flow(line, cont_prefix, cont_pad, segments, node_id)
    local function continuation()
      emit(line, node_id)
      line = new_line()
      line:add(cont_prefix, "TypeScopeChrome")
      line:add(string.rep(" ", cont_pad))
      return line
    end

    for _, seg in ipairs(segments) do
      local text, group = seg[1], seg[2]
      while text ~= "" do
        local avail = opts.max_width - line.width
        if strwidth(text) <= avail then
          line:add(text, group)
          text = ""
        elseif avail < 8 and line.width > cont_pad then
          -- too little room to start; push the whole segment down a line
          line = continuation()
        else
          local cut = math.max(1, find_break_point(text, avail))
          line:add(text:sub(1, cut), group)
          text = text:sub(cut + 1):gsub("^%s+", "")
          line = continuation()
        end
      end
    end
    emit(line, node_id)
  end

  ---@param node typescope.Node
  ---@param bars string accumulated ancestor chrome for this node's children
  ---@param branch string chrome immediately before this node's name
  local function render_node(node, bars, branch, depth)
    local line = new_line()
    local marker
    if depth == 0 then
      marker = is_expandable(node) and (node.state.expanded and style.expanded or style.collapsed)
        or style.leaf
      line:add(marker, "TypeScopeChrome")
    else
      line:add(branch, "TypeScopeChrome")
      if is_expandable(node) then
        line:add(node.state.expanded and style.expanded or style.collapsed, "TypeScopeChrome")
      end
    end

    local name_group = node.kind == "return" and "TypeScopeKeyword" or "TypeScopeField"
    if node.active then
      name_group = "TypeScopeActive"
    end
    line:add(node.name, name_group)

    -- align annotations within this sibling group
    local pad = (node._name_col or #node.name) - strwidth(node.name)
    line:add(string.rep(" ", pad + 2))

    local cont_prefix = depth == 0 and string.rep(" ", strwidth(marker or "")) or bars
    local cont_pad = line.width - strwidth(cont_prefix)

    local segments = {}
    local type_text = node.type.display or node.type.raw or "?"
    table.insert(segments, { type_text, "TypeScopeType" })
    if node.type.category == "unresolved" then
      table.insert(segments, { " " .. style.unresolved, "TypeScopeUnresolved" })
    end
    if node.badge then
      table.insert(segments, { " " .. node.badge, "TypeScopeBadge" })
    end
    if node.default then
      table.insert(segments, { " = ", "TypeScopeChrome" })
      table.insert(segments, { node.default, "TypeScopeDefault" })
    end
    local example = example_for(node, opts)
    if example then
      table.insert(segments, { "  " .. example, "TypeScopeExample" })
    end
    if is_expandable(node) and not node.state.expanded and depth == 0 then
      table.insert(segments, { "  (<CR> to expand)", "TypeScopeHint" })
    end

    flow(line, cont_prefix, cont_pad, segments, node.id)

    if node.state.expanded then
      local kids = node.children
      local name_col = 0
      for _, child in ipairs(kids) do
        local w = strwidth(child.name)
        if is_expandable(child) then
          w = w + strwidth(style.expanded)
        end
        name_col = math.max(name_col, w)
      end
      for i, child in ipairs(kids) do
        local last = i == #kids
        child._name_col = is_expandable(child) and (name_col - strwidth(style.expanded)) or name_col
        render_node(
          child,
          bars .. (last and string.rep(" ", strwidth(style.vert)) or style.vert),
          bars .. (last and style.last or style.branch),
          depth + 1
        )
      end
    end
  end

  for i, root in ipairs(roots) do
    if i > 1 then
      emit(new_line(), nil) -- blank spacer between top-level entries
    end
    root._name_col = strwidth(root.name)
    render_node(root, string.rep(" ", strwidth(style.expanded)), "", 0)
  end

  return result
end

-- exposed for testing and for the spike to hot-swap experiments
M._find_break_point = find_break_point

return M
