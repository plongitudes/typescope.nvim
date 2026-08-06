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
    -- help (?) replaces the view entirely: content routinely exceeds
    -- max_height, so an appended panel lands below the fold and is never seen
    if st.show_help then
      local lines = help_lines(st.width, st.extra_help)
      local highlights = {}
      for i, text in ipairs(lines) do
        highlights[i] = { line = i - 1, col_start = 0, col_end = #text, group = "TypeScopeHint" }
      end
      float.update(st.handle, {
        lines = lines,
        highlights = highlights,
        width = st.width,
        height = math.min(st.max_height, #lines),
      })
      vim.api.nvim_win_set_cursor(st.handle.win, { 1, 0 })
      return
    end
    st.result = render.render(st.roots, st.opts)
    local lines = vim.list_extend({}, st.result.lines)
    local highlights = st.result.highlights
    -- expanding deep subtrees produces wider content than the float opened
    -- with — grow the window (never shrink; up to max_width) or lines clip
    st.width = math.max(st.width, math.min(st.opts.max_width, st.result.width))
    float.update(st.handle, {
      lines = lines,
      highlights = highlights,
      ts_injections = st.result.ts_injections,
      lang = st.opts.lang,
      width = st.width,
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
    -- while help covers the view, st.result's line map is stale — node
    -- keymaps become no-ops instead of acting on invisible rows
    if not st.result or st.show_help then
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
    local node = node_under_cursor()
    st.show_help = not st.show_help
    if st.show_help then
      st.help_return_id = node and node.id or nil
      refresh()
    else
      refresh(st.help_return_id)
    end
  end)
  map(km.docstring, function()
    if st.opts.docstring and st.opts.docstring_pos then
      st.opts.docstring_expanded = not st.opts.docstring_expanded
      refresh()
    end
  end)
  -- Single-flight LLM generation, shared by the E keymap and the auto-open
  -- path: concurrent runs double requests AND nest title spinners (the inner
  -- one captures "generating…" as the original title and restores it
  -- forever — Tony's frozen-title screenshot).
  ---@param on_error? fun(err: string) override the default warn
  local function generate(on_error)
    if not args.on_llm or st.generating then
      return
    end
    st.generating = true
    -- flip upfront: render falls back to heuristics until values land, and
    -- each batch swaps its rows in as it arrives
    st.opts.example_kind = "llm"
    st.opts.show_examples = true
    -- the spinner starts only if generation is still running after a beat:
    -- a cache-served run (every reopen) finishes synchronously, and its
    -- one-frame "generating…" title flash read as real regeneration
    local spinner = nil
    local finished = false
    vim.defer_fn(function()
      if not finished and vim.api.nvim_win_is_valid(st.handle.win) then
        spinner = require("typescope.anim").title_spinner(st.handle.win, "generating")
      end
    end, 80)
    args.on_llm(st.roots, function(ok, err)
      st.generating = false
      finished = true
      if spinner then
        spinner.stop()
      end
      if not vim.api.nvim_win_is_valid(st.handle.win) then
        return
      end
      if ok then
        refresh()
      elseif err then
        if on_error then
          on_error(err)
        else
          vim.notify("typescope: " .. err .. " (keeping heuristic examples)", vim.log.levels.WARN)
        end
      end
    end, function(batches_done, batches_total)
      if spinner and batches_total and batches_total > 1 then
        spinner.set_label(("generating %d/%d"):format(math.min(batches_done + 1, batches_total), batches_total))
      end
      if vim.api.nvim_win_is_valid(st.handle.win) then
        refresh()
      end
    end)
  end

  map(km.llm_generate, function()
    if not args.on_llm then
      vim.notify("typescope: LLM examples need a live LSP session (not available in the spike)", vim.log.levels.INFO)
      return
    end
    -- an explicit press is permission to re-ask leaves the model whiffed on;
    -- the auto-run on open skips them (MISS sentinels) to avoid regenerating
    -- on every reopen
    require("typescope.examples").retry_misses(st.roots)
    generate()
  end)
  map(km.close, args.on_close)
  map("<Esc>", args.on_close)

  -- j/k jump between interactive rows — params and expandable sub-items —
  -- skipping display-only lines (detail blocks, wrapped continuations,
  -- header/rule). Past the last node they fall back to plain movement so
  -- the docstring section stays reachable and scrollable.
  local function jump(dir)
    if st.show_help then
      vim.cmd("normal! " .. (dir == 1 and "j" or "k"))
      return
    end
    local win = st.handle.win
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    local cur = st.result.line_to_node[lnum]
    local target
    local i = lnum + dir
    while i >= 1 and i <= vim.api.nvim_buf_line_count(st.handle.buf) do
      local id = st.result.line_to_node[i]
      if id and id ~= cur then
        target = i
        break
      end
      i = i + dir
    end
    if target then
      -- land on the node's PRIMARY line (a k arriving from below first hits
      -- the last line of a wrapped/detailed run)
      local id = st.result.line_to_node[target]
      while target > 1 and st.result.line_to_node[target - 1] == id do
        target = target - 1
      end
      vim.api.nvim_win_set_cursor(win, { target, 0 })
    else
      vim.cmd("normal! " .. (dir == 1 and "j" or "k"))
    end
  end
  map("j", function()
    jump(1)
  end)
  map("k", function()
    jump(-1)
  end)

  -- ledger (U6): the detail block follows the cursor. Re-render only when the
  -- node under the cursor changes; refresh(id) parks the cursor back on the
  -- node's primary row, and the id-equality guard turns the CursorMoved that
  -- move fires into a no-op (detail lines map to their owner, so resting on
  -- one keeps its block open).
  if st.opts.layout == "ledger" then
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = st.handle.buf,
      desc = "TypeScope: ledger detail block follows the cursor",
      callback = function()
        if not st.result or st.show_help or not vim.api.nvim_win_is_valid(st.handle.win) then
          return
        end
        local lnum = vim.api.nvim_win_get_cursor(st.handle.win)[1]
        local id = st.result.line_to_node[lnum]
        if id ~= st.opts.detail_id then
          st.opts.detail_id = id
          refresh(id)
        end
      end,
    })
  end

  st.result = render.render(st.roots, st.opts)

  return { opts = st.opts, refresh = refresh, generate = generate }
end

return M
