---@class typescope.Highlight
---@field line integer 0-indexed
---@field col_start integer byte offset
---@field col_end integer byte offset
---@field group string

---@class typescope.Injection
---@field line integer 0-indexed
---@field col_start integer byte offset
---@field text string source snippet to highlight with the language's TS parser
---@field mode "replace"|"overlay" replace: syntax colors supplant the base block group (so bold/italic from semantic groups don't bleed through); overlay: both apply (examples keep their dim styling)

---@class typescope.RenderResult
---@field lines string[]
---@field highlights typescope.Highlight[]
---@field ts_injections typescope.Injection[] annotation/default/example spans for real syntax highlighting
---@field line_to_node table<integer, string> 1-indexed line -> node id (continuation lines included)
---@field width integer display width of the widest line

---@class typescope.RenderOpts
---@field style typescope.Charset
---@field max_width integer resolved columns (callers use config.resolved_max_width)
---@field align? "left"|"right" name column alignment (default left)
---@field show_examples boolean
---@field example_kind "heuristic"|"llm"
---@field lang? string treesitter language for injected snippet highlighting
---@field header? string one-line call shape shown above the tree
---@field docstring? string full docstring text (render decides how much shows)
---@field docstring_expanded? boolean full text vs first paragraph
---@field docstring_pos? "top"|"bottom"|false where the docstring section sits

local M = {}

local strwidth = vim.api.nvim_strwidth

-- Accumulates (text, group) segments for one visual line, tracking byte
-- offsets for extmark highlights and display width for wrapping.
local Line = {}
Line.__index = Line

local function new_line()
  return setmetatable({ text = "", width = 0, hls = {}, inj = {} }, Line)
end

---@param text string
---@param group? string base highlight group
---@param inject? "replace"|"overlay" span is a source snippet for real TS highlighting
function Line:add(text, group, inject)
  if text == "" then
    return self
  end
  if group then
    table.insert(self.hls, { col_start = #self.text, col_end = #self.text + #text, group = group })
  end
  if inject then
    table.insert(self.inj, { col_start = #self.text, text = text, mode = inject })
  end
  self.text = self.text .. text
  self.width = self.width + strwidth(text)
  return self
end

--- Decide where to break annotation text that exceeds the available width.
--- Returns the byte index (1-based, inclusive) of the last character to keep
--- on the current line. `limit` is the max number of display cells available.
---
--- Heuristic (Tony's call): a comma followed by a space is the best break —
--- in Python type syntax that's always an argument boundary — otherwise any
--- whitespace. Only breaks in the back half of the line; a hard cut wastes
--- less vertical space than honoring a lone early break point.
---
--- NOTE: if ", " stops being a good boundary (e.g. annotations containing
--- Literal["a, b"] strings, or future non-Python languages), switch to real
--- syntax-aware breaks: vim.treesitter.get_string_parser(text, lang), then
--- break at the subscript/argument node boundary nearest the limit. Same
--- results for well-behaved annotations, but immune to commas inside strings.
---@param text string annotation text (assumed single-width chars)
---@param limit integer display cells available on this line
---@return integer
local function find_break_point(text, limit)
  local floor = math.max(1, math.floor(limit / 2))
  local best_space
  for i = limit, floor, -1 do
    local c = text:sub(i, i)
    if c == "," and text:sub(i + 1, i + 1) == " " then
      return i -- keep the comma at end of line; caller strips the leading space
    end
    if c == " " and not best_space then
      best_space = math.max(1, i - 1) -- break before the space, no trailing blank
    end
  end
  return best_space or limit
end

local is_expandable = require("typescope.model").is_expandable

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
  local result = { lines = {}, highlights = {}, ts_injections = {}, line_to_node = {}, width = 0 }

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
    for _, inj in ipairs(line.inj) do
      table.insert(
        result.ts_injections,
        { line = lnum - 1, col_start = inj.col_start, text = inj.text, mode = inj.mode }
      )
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
      -- injection only survives on unsplit spans: a wrapped fragment like
      -- "dict[str," is not parseable source, so continuations keep the base
      -- group color only
      local inject = seg[3]
      -- atomic segments (badges, origin tags, indicators) never split
      -- mid-word — they jump whole to the next line instead
      local atomic = seg[4]
      while text ~= "" do
        local avail = opts.max_width - line.width
        if strwidth(text) <= avail then
          line:add(text, group, text == seg[1] and inject or nil)
          text = ""
        elseif (atomic or avail < 8) and line.width > cont_pad then
          -- push the whole segment down a line
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
    -- every row carries a marker glyph — expandable (▾/▸) or leaf (·) — so
    -- names inside a sibling group align regardless of expandability
    -- (Tony's call, 2026-07-29)
    local marker = is_expandable(node) and (node.state.expanded and style.expanded or style.collapsed)
      or style.leaf
    if depth > 0 then
      line:add(branch, "TypeScopeChrome")
    end

    -- marker + name form one unit, aligned within the sibling group's column:
    -- left mode pads after the name, right mode pads before the marker
    local unit_width = strwidth(node.name) + strwidth(marker)
    local pad = math.max(0, (node._unit_col or unit_width) - unit_width)
    if opts.align == "right" then
      line:add(string.rep(" ", pad))
    end
    line:add(marker, "TypeScopeChrome")
    local name_group = node.kind == "return" and "TypeScopeKeyword"
      or node.kind == "type" and "TypeScopeType"
      or "TypeScopeField"
    if node.active then
      name_group = "TypeScopeActive"
    end
    line:add(node.name, name_group)
    if opts.align ~= "right" then
      line:add(string.rep(" ", pad))
    end
    line:add("  ")

    local cont_prefix = depth == 0 and "" or bars
    local cont_pad = line.width - strwidth(cont_prefix)

    local segments = {}
    local type_text = node.type.display or node.type.raw or "?"
    -- method "signatures" like (path: str) -> bytes and class-root category
    -- labels like (pydantic) aren't parseable expressions, so they keep
    -- block coloring
    local injectable = (node.kind ~= "method" and node.kind ~= "type") and "replace" or nil
    -- an unannotated param's declared type is only implicit Any; when we have
    -- pyright's inferred type, show just that instead of "Any ≈ T"
    if not (node.evaluated and type_text == "Any") then
      table.insert(segments, { type_text, "TypeScopeType", injectable })
    end
    if node.evaluated then
      table.insert(segments, { (type_text == "Any" and "" or " ") .. style.evaluated, "TypeScopeEvaluated" })
      table.insert(segments, { node.evaluated, "TypeScopeEvaluated" })
    end
    if node.type.category == "unresolved" then
      table.insert(segments, { " " .. style.unresolved, "TypeScopeUnresolved", nil, true })
    end
    if node.badge then
      table.insert(segments, { " " .. node.badge, "TypeScopeBadge", nil, true })
    end
    if node.origin then
      table.insert(segments, { " " .. style.inherit .. node.origin, "TypeScopeHint", nil, true })
    end
    if node.default then
      table.insert(segments, { " = ", "TypeScopeChrome" })
      table.insert(segments, { node.default, "TypeScopeDefault", "replace" })
    end
    local example = example_for(node, opts)
    if example then
      table.insert(segments, { "  ", nil })
      -- overlay: examples are hypothetical values, they keep their dim
      -- TypeScopeExample styling underneath the syntax colors. Atomic: an
      -- example jumps whole to the next line rather than splitting mid-word
      -- (still splits if longer than a full line).
      table.insert(segments, { example, "TypeScopeExample", "overlay", true })
    end
    if is_expandable(node) and not node.state.expanded and depth == 0 then
      table.insert(segments, { "  (<CR> to expand)", "TypeScopeHint" })
    end

    flow(line, cont_prefix, cont_pad, segments, node.id)

    if node.state.expanded then
      local kids = node.children
      local unit_col = 0
      for _, child in ipairs(kids) do
        -- all marker glyphs share one width, so units align uniformly
        unit_col = math.max(unit_col, strwidth(child.name) + strwidth(style.expanded))
      end
      for i, child in ipairs(kids) do
        local last = i == #kids
        child._unit_col = unit_col
        render_node(
          child,
          bars .. (last and string.rep(" ", strwidth(style.vert)) or style.vert),
          bars .. (last and style.last or style.branch),
          depth + 1
        )
      end
    end
  end

  -- ── sections (unification U1): header / docstring around the tree ──────
  local separators = {}
  local function emit_separator()
    table.insert(separators, #result.lines + 1)
    emit(new_line(), nil)
  end
  -- greedy word-wrap for prose/header text, hanging indent 2 on continuations
  local function emit_prose(text, group)
    local remaining = text
    local first = true
    while remaining ~= "" do
      local prefix = first and "" or "  "
      local avail = opts.max_width - strwidth(prefix)
      local line = new_line()
      line:add(prefix)
      if strwidth(remaining) <= avail then
        line:add(remaining, group)
        remaining = ""
      else
        local cut = math.max(1, find_break_point(remaining, avail))
        line:add(remaining:sub(1, cut), group)
        remaining = remaining:sub(cut + 1):gsub("^%s+", "")
      end
      emit(line, nil)
      first = false
    end
  end
  local function emit_docstring()
    local text = opts.docstring
    if not opts.docstring_expanded then
      text = text:match("^(.-)\n%s*\n") or text -- first paragraph
    end
    for _, doc_line in ipairs(vim.split(vim.trim(text), "\n")) do
      if doc_line == "" then
        emit(new_line(), nil)
      else
        emit_prose(doc_line, "TypeScopeDocstring")
      end
    end
  end

  local has_doc = opts.docstring ~= nil and opts.docstring ~= "" and opts.docstring_pos ~= nil and opts.docstring_pos ~= false
  if opts.header then
    -- the header is a one-liner by contract: a 48-param call shape must not
    -- eat the float, so the param list elides at width with the return type
    -- kept visible — run(app, *, host=…, …) -> None
    local header = opts.header
    if strwidth(header) > opts.max_width then
      local ret_part = header:match("%)(%s*->.*)$") or ""
      local body = header:sub(1, #header - #ret_part)
      local suffix = "…)" .. ret_part
      local budget = math.max(8, opts.max_width - strwidth(", " .. suffix))
      local cut = math.max(1, find_break_point(body, budget))
      -- drop the final (possibly cut-in-half) token so only whole params show
      header = body:sub(1, cut):gsub(",%s*[^,]*$", "") .. ", " .. suffix
    end
    emit_prose(header, "TypeScopeHeader")
  end
  if has_doc and opts.docstring_pos == "top" then
    emit_docstring()
  end
  if opts.header or (has_doc and opts.docstring_pos == "top") then
    emit_separator()
  end

  -- no spacer lines between top-level entries: the expander markers carry
  -- the visual grouping (Tony's call, 2026-07-26 — revisit if it feels dense)
  --
  -- roots share a name column so annotations align. Left mode caps
  -- participation at 16 cells — one ws_per_message_deflate must not drag
  -- every annotation to column 30 and force wraps; outliers sit ragged.
  -- Right mode is uncapped: padding lands before the name, so long names
  -- cost nothing extra (Tony's full-width request).
  local cap = opts.align == "right" and math.huge or 16
  local marker_w = strwidth(style.expanded)
  local root_col = 0
  for _, root in ipairs(roots) do
    local w = strwidth(root.name)
    if w <= cap then
      root_col = math.max(root_col, w + marker_w)
    end
  end
  for _, root in ipairs(roots) do
    local w = strwidth(root.name)
    root._unit_col = w <= cap and root_col or (w + marker_w)
    render_node(root, string.rep(" ", marker_w), "", 0)
  end

  if has_doc and opts.docstring_pos == "bottom" then
    emit_separator()
    emit_docstring()
  end

  -- separators stretch to the final content width, known only now
  for _, lnum in ipairs(separators) do
    local bar = string.rep(style.rule, math.max(4, result.width))
    result.lines[lnum] = bar
    table.insert(result.highlights, { line = lnum - 1, col_start = 0, col_end = #bar, group = "TypeScopeChrome" })
  end

  return result
end

-- exposed for testing and for the spike to hot-swap experiments
M._find_break_point = find_break_point

return M
