local model = require("typescope.model")
local render = require("typescope.render")
local float = require("typescope.float")
local config = require("typescope.config")

local M = {}

---@class typescope.Controller
---@field opts typescope.RenderOpts current render options (mutated by toggles)
---@field refresh fun(focus_id?: string)

---@class typescope.AttachArgs
---@field handle typescope.FloatHandle
---@field roots typescope.Node[]
---@field opts typescope.RenderOpts
---@field width integer fixed float width (kept stable during interaction)
---@field max_height integer
---@field on_close fun()
---@field on_recurse? fun(node: typescope.Node, done: fun()) lazily resolve a beyond-depth node
---@field on_llm? fun(roots: typescope.Node[], done: fun(ok: boolean, err: string?)) generate LLM examples for the visible tree
---@field extra_help? { [1]: string, [2]: string }[] host rows for the ? overlay

---@param width integer
---@param extra { [1]: string, [2]: string }[]? host-provided rows (e.g. spike harness keys)
local function help_lines(width, extra)
  local km = config.get().keymaps
  local rows = {
    { km.expand, "expand / collapse" },
    { km.collapse_node .. " / " .. km.expand_node, "collapse / expand node" },
    { km.collapse_all .. " / " .. km.expand_all, "collapse / expand all" },
    { km.toggle_examples, "toggle examples" },
    { km.llm_generate, "llm examples (ollama)" },
    { km.recurse, "recurse deeper" },
    { km.docstring, "toggle full docstring" },
    { km.close .. " / <Esc>", "close" },
    { km.help, "toggle this help" },
  }
  vim.list_extend(rows, extra or {})
  local lines = { string.rep("·", math.max(4, width)) }
  for _, row in ipairs(rows) do
    table.insert(lines, (" %-11s %s"):format(row[1], row[2]))
  end
  return lines
end

--- Wire tree navigation into an open TypeScope float. Returns a controller
--- whose refresh() re-renders in place — buffer content and window size change
--- in one synchronous block (float.update), so no partial frame is ever shown.
---@param args typescope.AttachArgs
---@return typescope.Controller
function M.attach(args)
  local st = {
    handle = args.handle,
    roots = args.roots,
    opts = args.opts,
    width = args.width,
    max_height = args.max_height,
    show_help = false,
    extra_help = args.extra_help,
    result = nil, ---@type typescope.RenderResult
  }

  local function refresh(focus_id)
    st.result = render.render(st.roots, st.opts)
    local lines = vim.list_extend({}, st.result.lines)
    local highlights = st.result.highlights
    if st.show_help then
      local extra = help_lines(st.width, st.extra_help)
      highlights = vim.list_extend({}, highlights)
      for i, text in ipairs(extra) do
        table.insert(lines, text)
        table.insert(highlights, {
          line = #lines - 1,
          col_start = 0,
          col_end = #text,
          group = "TypeScopeHint",
        })
      end
    end
    float.update(st.handle, {
      lines = lines,
      highlights = highlights,
      ts_injections = st.result.ts_injections,
      lang = st.opts.lang,
      height = math.min(st.max_height, #lines),
    })
    if focus_id then
      for lnum, id in pairs(st.result.line_to_node) do
        if id == focus_id then
          vim.api.nvim_win_set_cursor(st.handle.win, { lnum, 0 })
          break
        end
      end
    end
  end

  local function node_under_cursor()
    if not st.result then
      return nil
    end
    local lnum = vim.api.nvim_win_get_cursor(st.handle.win)[1]
    local id = st.result.line_to_node[lnum]
    return id and model.find(st.roots, id) or nil
  end

  local km = config.get().keymaps
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = st.handle.buf, nowait = true })
  end

  -- expanding a node whose children weren't resolved yet (beyond config
  -- depth) triggers lazy resolution instead of opening an empty branch
  local function recurse_into(node)
    if args.on_recurse and node._lazy and not node.state.loading then
      args.on_recurse(node, function()
        refresh(node.id)
      end)
      return true
    end
    return false
  end

  map(km.expand, function()
    local node = node_under_cursor()
    if not node then
      return
    end
    if not node.state.loaded and recurse_into(node) then
      return
    end
    if model.is_expandable(node) then
      node.state.expanded = not node.state.expanded
      refresh(node.id)
    end
  end)
  map(km.expand_node, function()
    local node = node_under_cursor()
    if not node then
      return
    end
    if not node.state.loaded and recurse_into(node) then
      return
    end
    if model.is_expandable(node) and not node.state.expanded then
      node.state.expanded = true
      refresh(node.id)
    end
  end)
  map(km.collapse_node, function()
    local node = node_under_cursor()
    if not node then
      return
    end
    if model.is_expandable(node) and node.state.expanded then
      node.state.expanded = false
      refresh(node.id)
    else
      -- on a leaf or already-collapsed node: jump to the parent and fold it
      -- (neo-tree convention)
      local parent = model.parent(st.roots, node.id)
      if parent then
        parent.state.expanded = false
        refresh(parent.id)
      end
    end
  end)
  map(km.expand_all, function()
    local node = node_under_cursor()
    model.walk(st.roots, function(n)
      if model.is_expandable(n) then
        n.state.expanded = true
      end
    end)
    refresh(node and node.id)
  end)
  map(km.collapse_all, function()
    local node = node_under_cursor()
    model.walk(st.roots, function(n)
      n.state.expanded = false
    end)
    -- the cursor's node likely vanished; land on its root ancestor
    refresh(node and node.id:match("^[^.]+"))
  end)
  map(km.toggle_examples, function()
    st.opts.show_examples = not st.opts.show_examples
    refresh()
  end)
  map(km.help, function()
    st.show_help = not st.show_help
    refresh()
  end)
  map(km.docstring, function()
    if st.opts.docstring and st.opts.docstring_pos then
      st.opts.docstring_expanded = not st.opts.docstring_expanded
      refresh()
    end
  end)
  map(km.llm_generate, function()
    if not args.on_llm then
      vim.notify("typescope: LLM examples need a live LSP session (not available in the spike)", vim.log.levels.INFO)
      return
    end
    if st.generating then
      return
    end
    st.generating = true
    -- flip upfront: render falls back to heuristics until values land, and
    -- each batch swaps its rows in as it arrives
    st.opts.example_kind = "llm"
    st.opts.show_examples = true
    local spinner = require("typescope.anim").title_spinner(st.handle.win, "generating")
    args.on_llm(st.roots, function(ok, err)
      st.generating = false
      spinner.stop()
      if not vim.api.nvim_win_is_valid(st.handle.win) then
        return
      end
      if ok then
        refresh()
      elseif err then
        vim.notify("typescope: " .. err .. " (keeping heuristic examples)", vim.log.levels.WARN)
      end
    end, function()
      if vim.api.nvim_win_is_valid(st.handle.win) then
        refresh()
      end
    end)
  end)
  map(km.recurse, function()
    local node = node_under_cursor()
    if not node then
      return
    end
    if not recurse_into(node) and not args.on_recurse then
      vim.notify("typescope: recursion needs a live LSP session (not available in the spike)", vim.log.levels.INFO)
    end
  end)
  map(km.close, args.on_close)
  map("<Esc>", args.on_close)

  st.result = render.render(st.roots, st.opts)

  return { opts = st.opts, refresh = refresh }
end

return M
