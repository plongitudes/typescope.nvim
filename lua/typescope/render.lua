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
---@field layout? "tree"|"table"|"ledger" flowing segments (default) vs column grid (U5) vs one-line rows + detail block (U6)
---@field align? "left"|"right" name column alignment (default left, tree layout)
---@field detail_id? string ledger layout: node whose row expands into a detail block
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
        priority = hl.priority, -- optional: row backgrounds sit under text
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
      or node.kind == "param" and "TypeScopeParam"
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
    -- method "signatures" like (path: str) -> bytes, class-root category
    -- labels like (pydantic), and overload shapes with elision marks aren't
    -- parseable expressions, so they keep block coloring
    local injectable = (node.kind ~= "method" and node.kind ~= "type" and node.kind ~= "overload") and "replace"
      or nil
    -- an unannotated param's declared type is only implicit Any; when we have
    -- pyright's inferred type, show just that instead of "Any ≈ T"
    if not (node.evaluated and type_text == "Any") then
      table.insert(segments, { type_text, "TypeScopeType", injectable })
    end
    -- an evaluation acquired BY expanding folds with its node (h hides it
    -- again); pipeline-acquired evaluations are always visible
    if node.evaluated and not (node.evaluated_on_expand and not node.state.expanded) then
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
    -- elision marks (`=…`, trailing `…`) carry no information beyond
    -- "something was here"; at full header brightness they blend into the
    -- names, so they render dimmed at the same hue (Tony, 2026-08-01)
    local hline = new_line()
    local hi = 1
    while hi <= #header do
      local s, e = header:find("=?…", hi)
      if not s then
        hline:add(header:sub(hi), "TypeScopeHeader")
        break
      end
      if s > hi then
        hline:add(header:sub(hi, s - 1), "TypeScopeHeader")
      end
      hline:add(header:sub(s, e), "TypeScopeHeaderDim")
      hi = e + 1
    end
    emit(hline, nil)
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
  -- ── table layout (U5): column grid with alternating row backgrounds ────
  -- name | */ | type | default | example | origin. Column widths are
  -- content-derived with caps on the wrappable columns (type, example);
  -- a wrapped cell continues on extra lines at its own column, all lines of
  -- a row sharing its background parity.
  local function render_table()
    local GAP = 2
    -- pass 1: collect visible rows as per-column segment lists
    local rows = {}
    local function collect(node, bars, branch, depth)
      local marker = is_expandable(node) and (node.state.expanded and style.expanded or style.collapsed)
        or style.leaf
      local name_group = node.kind == "return" and "TypeScopeKeyword"
        or node.kind == "type" and "TypeScopeType"
        or node.kind == "param" and "TypeScopeParam"
        or "TypeScopeField"
      if node.active then
        name_group = "TypeScopeActive"
      end
      local name_segs = {}
      if depth > 0 then
        table.insert(name_segs, { branch, "TypeScopeChrome" })
      end
      table.insert(name_segs, { marker, "TypeScopeChrome" })
      table.insert(name_segs, { node.name, name_group })

      local mode_segs = {}
      if node.pass_mode then
        table.insert(mode_segs, { node.pass_mode, "TypeScopeKeyword" })
      end

      local type_segs = {}
      local type_text = node.type.display or node.type.raw or "?"
      local injectable = (node.kind ~= "method" and node.kind ~= "type" and node.kind ~= "overload") and "replace"
        or nil
      if not (node.evaluated and type_text == "Any") then
        table.insert(type_segs, { type_text, "TypeScopeType", injectable })
      end
      if node.evaluated and not (node.evaluated_on_expand and not node.state.expanded) then
        table.insert(type_segs, { (#type_segs > 0 and " " or "") .. style.evaluated, "TypeScopeEvaluated" })
        table.insert(type_segs, { node.evaluated, "TypeScopeEvaluated" })
      end
      if node.type.category == "unresolved" then
        table.insert(type_segs, { " " .. style.unresolved, "TypeScopeUnresolved" })
      end
      if node.badge then
        table.insert(type_segs, { " " .. node.badge, "TypeScopeBadge" })
      end

      local default_segs = {}
      if node.default then
        table.insert(default_segs, { "= ", "TypeScopeChrome" })
        table.insert(default_segs, { node.default, "TypeScopeDefault", "replace" })
      end

      local example_segs = {}
      local example = example_for(node, opts)
      if example then
        table.insert(example_segs, { example, "TypeScopeExample", "overlay" })
      end

      local origin_segs = {}
      if node.origin then
        table.insert(origin_segs, { style.inherit .. node.origin, "TypeScopeHint" })
      end

      -- the tree layout's "(<CR> to expand)" hint is dropped here: the
      -- marker glyph carries it, and a hint column would be pure noise
      table.insert(rows, {
        node = node,
        cells = { name_segs, mode_segs, type_segs, default_segs, example_segs, origin_segs },
      })
      if node.state.expanded then
        for i, child in ipairs(node.children) do
          local last = i == #node.children
          collect(
            child,
            bars .. (last and string.rep(" ", strwidth(style.vert)) or style.vert),
            bars .. (last and style.last or style.branch),
            depth + 1
          )
        end
      end
    end
    for _, root in ipairs(roots) do
      collect(root, string.rep(" ", strwidth(style.expanded)), "", 0)
    end

    local function segs_width(segs)
      local w = 0
      for _, s in ipairs(segs) do
        w = w + strwidth(s[1])
      end
      return w
    end

    -- pass 2: column widths, capping the wrappable columns to fit max_width
    local WRAPPABLE = { [3] = true, [5] = true } -- type, example
    local widths = {}
    for c = 1, 6 do
      widths[c] = 0
      for _, row in ipairs(rows) do
        widths[c] = math.max(widths[c], segs_width(row.cells[c]))
      end
    end
    local function grid_width()
      local w = 0
      for c = 1, 6 do
        if widths[c] > 0 then
          w = w + widths[c] + (w > 0 and GAP or 0)
        end
      end
      return w
    end
    local over = grid_width() - opts.max_width
    if over > 0 then
      -- shrink type first, then example, floors at 16 cells each
      for _, c in ipairs({ 3, 5 }) do
        if over > 0 and widths[c] > 16 then
          local cut = math.min(over, widths[c] - 16)
          widths[c] = widths[c] - cut
          over = over - cut
        end
      end
    end

    -- wrap one cell's segments into width-bounded slices; a wrapped cell
    -- loses its injections (fragments aren't parseable source)
    local function wrap_cell(segs, width)
      if segs_width(segs) <= width then
        return { segs }
      end
      local slices, current, cur_w = {}, {}, 0
      for _, seg in ipairs(segs) do
        local text, group = seg[1], seg[2]
        while text ~= "" do
          local avail = width - cur_w
          if strwidth(text) <= avail then
            table.insert(current, { text, group })
            cur_w = cur_w + strwidth(text)
            text = ""
          elseif avail < 6 and cur_w > 0 then
            table.insert(slices, current)
            current, cur_w = {}, 0
          else
            local cut = math.max(1, find_break_point(text, avail))
            local clean = text:sub(cut, cut):match("[%s,]") ~= nil or text:sub(cut + 1, cut + 1):match("%s") ~= nil
            if cur_w > 0 and not clean then
              -- forced mid-word cut on a shared slice reads terribly — give
              -- the segment a fresh slice with the full column width instead
              table.insert(slices, current)
              current, cur_w = {}, 0
            else
              table.insert(current, { text:sub(1, cut), group })
              text = text:sub(cut + 1):gsub("^%s+", "")
              table.insert(slices, current)
              current, cur_w = {}, 0
            end
          end
        end
      end
      if #current > 0 then
        table.insert(slices, current)
      end
      return slices
    end

    -- pass 3: emit — each row spans max(slices) lines; every line of a row
    -- carries the row's background parity across the full grid width
    for ri, row in ipairs(rows) do
      local sliced = {}
      local height = 1
      for c = 1, 6 do
        sliced[c] = wrap_cell(row.cells[c], math.max(widths[c], 1))
        height = math.max(height, #sliced[c])
      end
      for k = 1, height do
        local line = new_line()
        for c = 1, 6 do
          if widths[c] > 0 then
            if line.width > 0 then
              line:add(string.rep(" ", GAP))
            end
            local col_start = line.width
            for _, seg in ipairs(sliced[c][k] or {}) do
              -- injections survive only in unsplit cells
              local inject = #sliced[c] == 1 and seg[3] or nil
              line:add(seg[1], seg[2], inject)
            end
            local pad = widths[c] - (line.width - col_start)
            if pad > 0 then
              line:add(string.rep(" ", pad))
            end
          end
        end
        if ri % 2 == 1 then
          table.insert(line.hls, {
            col_start = 0,
            col_end = #line.text,
            group = "TypeScopeRowOdd",
            priority = 90, -- under the text groups: bg only shines through
          })
        end
        emit(line, row.node.id)
      end
    end
  end

  -- ── ledger layout (U6): one line per node, cursor-follow detail block ──
  -- Rows carry identity + discriminators only (name, pass mode, type, short
  -- default); everything read one-at-a-time (≈ evaluation, example, origin,
  -- long defaults) lives in the detail block under opts.detail_id's row.
  -- Rows NEVER wrap — the single-line invariant is what keeps the float
  -- narrow and scanning cheap.
  local function render_ledger()
    local NAME_CAP = 24
    -- middle-ellipsis: identifiers discriminate at both ends
    -- (ws_per_message_deflate → ws_per_mess…ge_deflate)
    local function capped_name(name)
      if strwidth(name) <= NAME_CAP then
        return name
      end
      local keep = NAME_CAP - 1
      local front = math.ceil(keep / 2)
      return name:sub(1, front) .. "…" .. name:sub(-(keep - front))
    end

    -- pass 1: visible rows, tree chrome carried like the other layouts
    local rows = {}
    local function collect(node, bars, branch, depth)
      table.insert(rows, { node = node, bars = bars, branch = branch, depth = depth })
      if node.state.expanded then
        for i, child in ipairs(node.children) do
          local last = i == #node.children
          collect(
            child,
            bars .. (last and string.rep(" ", strwidth(style.vert)) or style.vert),
            bars .. (last and style.last or style.branch),
            depth + 1
          )
        end
      end
    end
    for _, root in ipairs(roots) do
      collect(root, string.rep(" ", strwidth(style.expanded)), "", 0)
    end

    -- pass 2: shared name column (chrome + gutter + capped name); the pass
    -- gutter exists only when some visible row actually uses it
    local has_mode = false
    for _, r in ipairs(rows) do
      has_mode = has_mode or r.node.pass_mode ~= nil
    end
    local marker_w = strwidth(style.expanded) -- all markers share one width
    local name_col = 0
    for _, r in ipairs(rows) do
      local w = (r.depth > 0 and strwidth(r.branch) or 0)
        + marker_w
        + (has_mode and 2 or 0)
        + strwidth(capped_name(r.node.name))
      name_col = math.max(name_col, w)
    end

    for _, r in ipairs(rows) do
      local node = r.node
      local detail = node.id == opts.detail_id
      local line = new_line()
      if r.depth > 0 then
        line:add(r.branch, "TypeScopeChrome")
      end
      local marker = is_expandable(node) and (node.state.expanded and style.expanded or style.collapsed)
        or style.leaf
      line:add(marker, "TypeScopeChrome")
      if has_mode then
        if node.pass_mode then
          line:add(node.pass_mode .. " ", "TypeScopeKeyword")
        else
          line:add("  ")
        end
      end
      local name_group = node.kind == "return" and "TypeScopeKeyword"
        or node.kind == "type" and "TypeScopeType"
        or node.kind == "param" and "TypeScopeParam"
        or "TypeScopeField"
      if node.active then
        name_group = "TypeScopeActive"
      end
      line:add(capped_name(node.name), name_group)
      line:add(string.rep(" ", math.max(0, name_col - line.width)) .. "  ")

      local type_text = node.type.display or node.type.raw or "?"
      local evaluated_visible = node.evaluated
        and not (node.evaluated_on_expand and not node.state.expanded)
      -- an unannotated param's declared type is only implicit Any — show the
      -- inferred view as the type itself (the detail block then skips it)
      local type_is_evaluation = evaluated_visible and type_text == "Any"
      if type_is_evaluation then
        type_text = node.evaluated
      end
      local injectable = not type_is_evaluation
        and (node.kind ~= "method" and node.kind ~= "type" and node.kind ~= "overload")
        and "replace"
        or nil
      local type_group = type_is_evaluation and "TypeScopeEvaluated" or "TypeScopeType"

      -- indicators that stay whole; the type absorbs any truncation
      local tail = {}
      if node.type.category == "unresolved" then
        table.insert(tail, { " " .. style.unresolved, "TypeScopeUnresolved" })
      end
      if node.badge then
        table.insert(tail, { " " .. node.badge, "TypeScopeBadge" })
      end
      local tail_w = 0
      for _, s in ipairs(tail) do
        tail_w = tail_w + strwidth(s[1])
      end

      -- inline default only on non-detail rows (the block carries the full
      -- value); long defaults elide to `=…` rather than widening every row
      local default_text = nil
      if node.default and not detail then
        default_text = strwidth(node.default) <= 12 and node.default or nil
      end
      local budget = opts.max_width - line.width - tail_w
      local def_w = default_text and (3 + strwidth(default_text)) or (node.default and not detail and 4 or 0)
      if strwidth(type_text) + def_w > budget then
        default_text = nil -- degrade the default before touching the type
        def_w = node.default and not detail and 4 or 0
      end
      if strwidth(type_text) + def_w > budget then
        type_text = type_text:sub(1, math.max(4, budget - def_w - 1)) .. "…"
        injectable = nil -- a truncated fragment isn't parseable source
      end
      line:add(type_text, type_group, injectable)
      for _, s in ipairs(tail) do
        line:add(s[1], s[2])
      end
      if node.default and not detail then
        line:add("  =", "TypeScopeChrome")
        if default_text then
          line:add(default_text, "TypeScopeDefault", "replace")
        else
          line:add("…", "TypeScopeChrome")
        end
      end
      emit(line, node.id)

      -- ── detail block: the focused row's read-one-at-a-time facts ─────────
      if detail then
        local dprefix = r.bars .. style.vert
        local function detail_line(segments)
          local dline = new_line()
          dline:add(dprefix, "TypeScopeChrome")
          flow(dline, dprefix, 2, segments, node.id)
        end
        if evaluated_visible and not type_is_evaluation then
          local segs = { { style.evaluated, "TypeScopeEvaluated" } }
          local owner = node.evaluated_owner
          -- name the annotation piece the evaluation belongs to when it
          -- isn't the whole annotation (multi-ref unions)
          if owner and owner ~= (node.type.display or node.type.raw) then
            table.insert(segs, { owner .. " = ", "TypeScopeEvaluated" })
          end
          -- overlay: real syntax colors over the dim ≈ base (flow drops the
          -- injection automatically if the value wraps)
          table.insert(segs, { node.evaluated, "TypeScopeEvaluated", "overlay" })
          detail_line(segs)
        end
        local info = {}
        if node.default then
          table.insert(info, { "= ", "TypeScopeChrome" })
          table.insert(info, { node.default, "TypeScopeDefault", "replace" })
        end
        local example = example_for(node, opts)
        if example then
          table.insert(info, { (#info > 0 and "   " or "") .. "e.g. ", "TypeScopeHint" })
          table.insert(info, { example, "TypeScopeExample", "overlay", true })
        end
        if node.origin then
          table.insert(info, { (#info > 0 and "   " or "") .. style.inherit .. node.origin, "TypeScopeHint", nil, true })
        end
        if #info > 0 then
          detail_line(info)
        end
      end
    end
  end

  if opts.layout == "table" then
    render_table()
  elseif opts.layout == "ledger" then
    render_ledger()
  else
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

--- Shrink a member list — Literal[...], a union, or a {field} shape — to a
--- display budget by keeping whole leading members and counting the rest:
--- Literal['auto', 'none', …+2]. A bare "…" carries no information; the
--- count at least says how much is hidden (density-theory prescription).
--- NOTE: the separator split is naive — a member containing ", " inside
--- nested brackets (dict[str, int]) splits wrong, but this only runs on
--- over-budget text where the elision marker already signals imprecision.
---@param text string
---@param budget integer display cells available
---@return string
local function elide_members(text, budget)
  if strwidth(text) <= budget then
    return text
  end
  local sep = ", "
  local head, body, tail = text:match("^([%w%._]+%[)(.*)(%])$")
  if not head then
    if text:sub(1, 1) == "{" then
      head, body, tail = "{", text:sub(2, -2), "}"
    elseif text:find(" | ", 1, true) then
      head, body, tail, sep = "", text, "", " | "
    else
      return text:sub(1, math.max(4, budget - 1)) .. "…"
    end
  end
  local members = vim.split(body, sep, { plain = true })
  for n = #members - 1, 1, -1 do
    local parts = {}
    for i = 1, n do
      parts[i] = members[i]
    end
    parts[n + 1] = ("…+%d"):format(#members - n)
    local candidate = head .. table.concat(parts, sep) .. tail
    if strwidth(candidate) <= budget then
      return candidate
    end
  end
  return head .. "…" .. tail
end

-- The active param's detail may take up to this many wrapped lines; only
-- past the cap does the shape start eliding members (Tony: wrap when out of
-- room — a short union shows in full, a 53-member Literal still can't eat
-- the float).
local LADDER_MAX_LINES = 3

---@class typescope.LadderOpts
---@field max_width integer
---@field show_examples boolean
---@field example_kind "heuristic"|"llm"
---@field style? typescope.Charset for the ≈ glyph (defaults to unicode's)
---@field fn_name? string callee name — heads the signature block
---@field ret? string return type shown as `-> ret` in the signature block
---@field badge? string overload badge, e.g. "[2/2]" (signature block tail)
---@field params? { name: string, active: boolean }[] the signature's params

--- Insert-mode ladder (U6): a K-consistent signature block —
--- `open(file, mode, …) -> TextIOWrapper [1/7]` with EVERY param name (no
--- `=…`, wrapped freely so all names stay visible, active one highlighted) —
--- a rule, then the active parameter's detail: type, SHAPE (alias/union
--- evaluation like OpenTextMode's legal values, or a resolved class's field
--- list), default, example. The detail WRAPS when out of room (hanging
--- indent, up to LADDER_MAX_LINES); beyond the cap the shape — the only
--- unbounded segment — elides member-by-member. Zero manual density
--- controls while the user is mid-call. Pure, like render().
---@param node typescope.Node the active param
---@param opts typescope.LadderOpts
---@return typescope.RenderResult
function M.ladder(node, opts)
  local eval_glyph = opts.style and opts.style.evaluated or "≈ "
  local type_text = node.type.display or node.type.raw or "?"
  if node.evaluated and type_text == "Any" then
    type_text = node.evaluated
  end
  -- the param's shape: what pyright evaluated the annotation to (valid
  -- values / union expansion), or the resolved class's own fields
  local shape = nil
  if node.evaluated and type_text ~= node.evaluated then
    shape = node.evaluated
  elseif #node.children > 0 then
    local names = {}
    for _, child in ipairs(node.children) do
      names[#names + 1] = child.name
    end
    shape = "{" .. table.concat(names, ", ") .. "}"
  end
  local example = opts.show_examples
      and (node.example[opts.example_kind] or node.example.heuristic)
    or nil

  ---@param shape_text? string
  ---@return { [1]: string, [2]: string?, [3]: string?, [4]: boolean? }[]
  local function segs_for(shape_text)
    local segs = {}
    local function seg(text, group, inject, atomic)
      table.insert(segs, { text, group, inject, atomic })
    end
    seg(node.name, "TypeScopeActive")
    seg(": ", "TypeScopeChrome")
    seg(type_text, node.evaluated and type_text == node.evaluated and "TypeScopeEvaluated" or "TypeScopeType", "replace")
    if shape_text then
      seg(" " .. eval_glyph, "TypeScopeEvaluated")
      -- overlay injection: values keep their real syntax colors (str/int/
      -- Literal strings each their own — Tony's per-piece color direction)
      -- over the dim ≈ base; the parser colors the valid prefix of elided
      -- text and leaves …+N alone. The {field} shape isn't source.
      seg(shape_text, "TypeScopeEvaluated", shape == node.evaluated and "overlay" or nil)
    end
    if node.default then
      seg(" = ", "TypeScopeChrome")
      seg(node.default, "TypeScopeDefault", "replace")
    end
    if example then
      seg("   e.g. ", "TypeScopeHint")
      seg(example, "TypeScopeExample", "overlay", true)
    end
    return segs
  end

  -- wrap segments into width-bounded lines with a hanging indent (mirrors
  -- render()'s flow: injection survives only on unsplit segments, atomic
  -- segments jump whole to the next line)
  ---@param segs { [1]: string, [2]: string?, [3]: string?, [4]: boolean? }[]
  ---@param cont_indent integer
  local function wrap_segs(segs, cont_indent)
    local lines = {}
    local line = new_line()
    local function continuation()
      table.insert(lines, line)
      line = new_line()
      line:add(string.rep(" ", cont_indent))
    end
    for _, seg in ipairs(segs) do
      local text, group, inject, atomic = seg[1], seg[2], seg[3], seg[4]
      local whole = text
      while text ~= "" do
        local avail = opts.max_width - line.width
        if strwidth(text) <= avail then
          line:add(text, group, text == whole and inject or nil)
          text = ""
        elseif (atomic or avail < 8) and line.width > cont_indent then
          continuation()
        else
          local cut = math.max(1, find_break_point(text, avail))
          line:add(text:sub(1, cut), group)
          text = text:sub(cut + 1):gsub("^%s+", "")
          continuation()
        end
      end
    end
    table.insert(lines, line)
    return lines
  end

  local cont_indent = math.min(strwidth(node.name) + 2, 12)
  ---@param shape_text? string
  local function layout(shape_text)
    return wrap_segs(segs_for(shape_text), cont_indent)
  end

  local detail = layout(shape)
  if #detail > LADDER_MAX_LINES and shape then
    -- budget = the cap's capacity minus everything that isn't the shape;
    -- wrapping wastes cells at break points, so shrink in steps before
    -- giving the shape up entirely
    local fixed = 3 -- " ≈ " glyph
    for _, seg in ipairs(segs_for(nil)) do
      fixed = fixed + strwidth(seg[1])
    end
    local capacity = LADDER_MAX_LINES * opts.max_width - cont_indent * (LADDER_MAX_LINES - 1)
    for _, factor in ipairs({ 1, 0.85, 0.7 }) do
      local budget = math.floor((capacity - fixed) * factor)
      if budget >= 12 then
        detail = layout(elide_members(shape, budget))
        if #detail <= LADDER_MAX_LINES then
          break
        end
      end
    end
    if #detail > LADDER_MAX_LINES then
      detail = layout(nil)
    end
  end

  local result = { lines = {}, highlights = {}, ts_injections = {}, line_to_node = {}, width = 0 }
  local function push(l, node_id)
    table.insert(result.lines, l.text)
    result.line_to_node[#result.lines] = node_id
    for _, hl in ipairs(l.hls) do
      table.insert(result.highlights, { line = #result.lines - 1, col_start = hl.col_start, col_end = hl.col_end, group = hl.group })
    end
    for _, inj in ipairs(l.inj) do
      table.insert(result.ts_injections, { line = #result.lines - 1, col_start = inj.col_start, text = inj.text, mode = inj.mode })
    end
    result.width = math.max(result.width, l.width)
  end

  -- signature block: K-consistent header — name(params) -> ret [i/m] — with
  -- every param name (defaults elided entirely, not marked), the active one
  -- highlighted, wrapped freely so all names stay visible
  local rule_lnum = nil
  if opts.fn_name and opts.params and #opts.params > 0 then
    local hsegs = {}
    local function hseg(text, group, inject, atomic)
      table.insert(hsegs, { text, group, inject, atomic })
    end
    hseg(opts.fn_name, "TypeScopeHeader")
    hseg("(", "TypeScopeHeader")
    for i, p in ipairs(opts.params) do
      -- atomic: a name never splits mid-word; its comma stays behind on the
      -- previous line, so no line ever starts with ", "
      hseg(p.name, p.active and "TypeScopeActive" or "TypeScopeParam", nil, true)
      if i < #opts.params then
        hseg(", ", "TypeScopeChrome")
      end
    end
    hseg(")", "TypeScopeHeader")
    if opts.ret then
      hseg(" -> ", "TypeScopeChrome")
      hseg(opts.ret, "TypeScopeType", "replace", true)
    end
    if opts.badge then
      hseg(" " .. opts.badge, "TypeScopeBadge", nil, true)
    end
    for _, hline in ipairs(wrap_segs(hsegs, math.min(strwidth(opts.fn_name) + 1, 12))) do
      push(hline, nil)
    end
    push(new_line(), nil) -- rule placeholder, stretched to width below
    rule_lnum = #result.lines
  end

  for _, dline in ipairs(detail) do
    push(dline, node.id)
  end
  if rule_lnum then
    local bar = string.rep(opts.style and opts.style.rule or "─", math.max(4, result.width))
    result.lines[rule_lnum] = bar
    table.insert(result.highlights, { line = rule_lnum - 1, col_start = 0, col_end = #bar, group = "TypeScopeChrome" })
  end
  return result
end

-- exposed for testing and for the spike to hot-swap experiments
M._find_break_point = find_break_point

return M
