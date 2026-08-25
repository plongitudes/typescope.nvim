local model = require("typescope.model")
local render = require("typescope.render")
local float = require("typescope.float")
local config = require("typescope.config")

local M = {}

--- Where a width grow has reached at `t` (0..1 through its duration).
--- Ease-out cubic: most of the travel happens up front, so the window is out of
--- the way early and the last columns drift rather than lurch.
---
--- Pulled out as a pure function because the e2e can only sample the real
--- window from the event loop, and how many samples land inside a 400ms grow
--- depends on machine load — enough to pass alone and fail under the suite
--- runner. The curve is testable exactly; the wiring is one call site.
---@param from integer
---@param to integer
---@param t number
---@return integer
function M._grow_ease(from, to, t)
  if t <= 0 then
    return from
  end
  if t >= 1 then
    return to
  end
  return math.floor(from + (to - from) * (1 - (1 - t) ^ 3) + 0.5)
end

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
    { km.collapse_all .. " / " .. km.expand_all, "collapse all / expand all + details" },
    { km.toggle_examples, "toggle examples" },
    { km.llm_generate, "llm examples (ollama)" },
    { km.docstring, "docstring: jump in / collapse back" },
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
  local examples = require("typescope.examples")
  -- render is pure: it can't ask the examples module what's still in flight,
  -- so hand it the predicate (38c). Only consulted in llm mode, and a leaf's
  -- hash is O(1) — heuristic renders and settled trees pay nothing.
  st.opts.example_pending = examples.awaiting

  -- forward declaration: the reveal timer below drives frames by calling
  -- refresh(), which is defined further down. Without this, that reference
  -- binds to a global (nil) instead of the local, and the wave dies on its
  -- first tick with nothing to show for it.
  local refresh ---@type fun(focus_id?: string)

  -- ONE frame clock for every animation (jit). Measured cost of a full frame
  -- — render + float.update + treesitter injections + forced redraw, on a
  -- 14-param ledger — is 1.18ms, so 60fps spends ~7% of the budget. The old
  -- shape (a timer per effect, each calling refresh()) both doubled that work
  -- and let two animations tear against each other; one clock, one repaint
  -- per frame, and every animation is a pure function of wall-clock time.
  local FRAME_MS = 16 -- 60fps
  local WAVE_PERIOD_MS = 1400 -- one full traverse of the pending bar
  local REVEAL_MS = 675
  local REVEAL_STAGGER_MS = 90 -- rows of a landed batch cascade, not flash
  -- The float opens into its new width instead of snapping there. Landed
  -- values are routinely wider than the 28-cell bar that stood in for them, so
  -- the frame that lands a batch used to widen the window by a dozen columns
  -- in one step — the loudest single event in the whole transition. Growing
  -- under the fall reads as the value pushing the window open, and the tail
  -- the window has yet to uncover is still bar, not settled text.
  --
  -- Shorter than REVEAL_MS on purpose: the window finishes opening while
  -- blocks are still falling, so the two don't end on the same frame and the
  -- animation has no flat tail.
  local GROW_MS = 400
  -- How long the bars are willing to wait before they stop moving. A pending
  -- row animates because a request is out; if that request never comes back —
  -- curl wedged, or a callback orphaned when its float closed — nothing
  -- retires the claim, and the clock repaints at 60fps for as long as the
  -- editor lives. That is what ran for hours behind the 20GB nvim (Tony,
  -- 2026-08-24). The leak underneath it is fixed (float.lua turns off undo on
  -- the float buffer), but an animation with no end is still wrong on a
  -- laptop.
  --
  -- Generous on purpose: a batch of 8 asks for ~224 tokens, which is 19-27s on
  -- an 8GB M1, and a cold model load can precede it. Three minutes is many
  -- times the worst honest case. Past it the bars simply stand still — the
  -- answer is not abandoned, and a late one still paints, because
  -- examples.on_landed refreshes whether or not a clock is running.
  local PENDING_MAX_MS = 180000
  local waiting_since = nil ---@type integer? hrtime the current wait began
  local reveals = {} ---@type table<string, integer> node id -> hrtime its wave starts
  local was_pending = {} ---@type table<string, boolean> pending as of the last paint
  local clock = nil
  local grow = nil ---@type { from: integer, to: integer, start: integer }?

  --- The width to paint this frame: the grow's eased position, or the settled
  --- width when nothing is growing. Retires the grow once it arrives.
  ---@return integer
  local function grown_width()
    if not grow then
      return st.width
    end
    local t = (vim.uv.hrtime() - grow.start) / 1e6 / GROW_MS
    if t >= 1 then
      grow = nil
      return st.width
    end
    return M._grow_ease(grow.from, grow.to, t)
  end

  --- Anything still moving? Pending bars travel; landed rows sweep; the window
  --- opens. The grow is listed so the clock outlives a reveal that somehow
  --- retires first — otherwise the window would stop half-open.
  ---
  --- A wait that has gone on past PENDING_MAX_MS stops counting as movement.
  local function animating()
    local waiting = examples.any_awaiting()
    if not waiting then
      waiting_since = nil
    elseif not waiting_since then
      waiting_since = vim.uv.hrtime()
    elseif (vim.uv.hrtime() - waiting_since) / 1e6 > PENDING_MAX_MS then
      waiting = false
    end
    return waiting or next(reveals) ~= nil or grow ~= nil
  end

  local function stop_clock()
    if clock then
      clock:stop()
      clock:close()
      clock = nil
    end
  end

  local function sync_clock()
    if not animating() or not config.get().ui.animations then
      -- animations off still gets the bar, just standing still
      return stop_clock()
    end
    if clock then
      return
    end
    clock = vim.uv.new_timer()
    clock:start(
      FRAME_MS,
      FRAME_MS,
      vim.schedule_wrap(function()
        if not vim.api.nvim_win_is_valid(st.handle.win) then
          return stop_clock()
        end
        local t = vim.uv.hrtime()
        for id, r in pairs(reveals) do
          if (t - r.start) / 1e6 >= REVEAL_MS then
            reveals[id] = nil
          end
        end
        -- paint first, THEN decide: the frame that retires the last animation
        -- is the one that shows the settled values
        if not pcall(refresh) or not animating() then
          stop_clock()
        end
      end)
    )
  end

  st.opts.example_reveal = function(node)
    local r = reveals[node.id]
    if not r then
      return nil
    end
    local t = (vim.uv.hrtime() - r.start) / 1e6
    if t <= 0 then
      return 0, r.phase, r.width -- staggered behind an earlier row: hold the frozen wave
    end
    return t < REVEAL_MS and t / REVEAL_MS or nil, r.phase, r.width
  end

  --- Queue a wave for every leaf that stopped being pending since the last
  --- paint. Runs BEFORE the render so the frame that first shows a value also
  --- shows it fully barred — otherwise the value is already on screen by the
  --- time the wave starts and the animation has nothing left to reveal.
  local function sync_reveals()
    local now, landed = {}, {}
    model.walk(st.roots, function(n)
      if examples.awaiting(n) then
        now[n.id] = true
      elseif was_pending[n.id] then
        table.insert(landed, n.id)
      end
    end)
    was_pending = now
    -- something came back, so the wait that is running is a fresh one: a
    -- generation of several batches re-arms the watchdog at each landing
    -- rather than being timed as one long silence
    if #landed > 0 then
      waiting_since = nil
    end
    local base = vim.uv.hrtime()
    for i, id in ipairs(landed) do
      -- freeze the wave where the eye last saw it, then let it fall from
      -- there: st.opts.example_phase is this frame's phase, set just above
      -- ...and the width it froze at, alongside the phase. The wave is drawn
      -- to the float's right edge, and that edge is about to move: the values
      -- that just landed are what widen the float. Left to follow it, the
      -- wave's own wavelength is recomputed against a wider run every frame of
      -- the grow, so it stretches while it falls (Tony). Frozen means frozen —
      -- st.width here is still the pre-landing width, because the render that
      -- discovers the new one has not run yet.
      reveals[id] = {
        start = base + (i - 1) * REVEAL_STAGGER_MS * 1e6,
        phase = st.opts.example_phase or 0,
        width = st.width,
      }
    end
  end

  function refresh(focus_id)
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
    -- phase first: the wave's position is a function of the clock, never
    -- accumulated state (a dropped frame skips ahead instead of stretching the
    -- animation), and sync_reveals freezes newly-landed rows AT this value
    st.opts.example_phase = (vim.uv.hrtime() / 1e6 % WAVE_PERIOD_MS) / WAVE_PERIOD_MS
    sync_reveals()
    -- The width the float already has. Two things need it: the rules under the
    -- header and above the docstring stretch to at least it, so a row that
    -- re-flows narrower on the frame it settles doesn't drag them in with it;
    -- and a pending wave runs out to it, so the bar is already as wide as the
    -- landed value's will be. One frame behind the render it feeds, which is
    -- what keeps it from chasing its own tail — the bar reaching the edge is
    -- what makes the edge stay put.
    st.opts.window_width = st.width
    st.result = render.render(st.roots, st.opts)
    sync_clock()
    local lines = vim.list_extend({}, st.result.lines)
    local highlights = st.result.highlights
    -- expanding deep subtrees produces wider content than the float opened
    -- with — grow the window (never shrink; up to max_width) or lines clip
    local target = st.width -- the width we were already headed for
    local shown = grown_width() -- ...and the one actually on screen, mid-grow
    st.width = math.max(st.width, math.min(st.opts.max_width, st.result.width))
    -- Only a reveal animates the growth. Everywhere else — <CR> to expand, the
    -- first paint — the new width is what the user asked for and should be
    -- there on the next frame, and outside a reveal there is no clock running
    -- to ease it with anyway.
    --
    -- Keyed on the TARGET moving, not on the window lagging behind it: mid-grow
    -- the window is always narrower than st.width, so testing that instead
    -- restarted the ease every single frame and turned a fixed 400ms curve into
    -- an exponential crawl that only ended when the reveals did.
    if st.width > target and next(reveals) ~= nil and config.get().ui.animations then
      grow = { from = shown, to = st.width, start = vim.uv.hrtime() }
    end
    float.update(st.handle, {
      lines = lines,
      highlights = highlights,
      ts_injections = st.result.ts_injections,
      lang = st.opts.lang,
      width = grown_width(),
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
  ---@param done? fun() runs when the node's children have landed
  local function recurse_into(node, done)
    if args.on_recurse and node._lazy and not node.state.loading then
      args.on_recurse(node, done or function()
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
    -- L means "show me everything", and in the ledger that has to include the
    -- detail blocks: only the cursor's row carries one, so an expanded tree
    -- still shows exactly one example at a time (d1x). Transient — the next
    -- move to a different node drops back to following the cursor. Parking
    -- detail_id on the current node is what makes that work: refresh() below
    -- moves the cursor, and the CursorMoved handler's id-equality guard turns
    -- that move into a no-op instead of cancelling the peek immediately.
    st.opts.detail_all = true
    st.opts.detail_id = node and node.id
    -- Flipping `expanded` isn't enough for a lazy node: its children don't
    -- exist yet, so L would mark `returns` open with nothing underneath.
    -- Resolve the lazy nodes in the tree we currently hold, then repaint once
    -- they've all landed rather than once per node (N cursor parks would
    -- fight each other). Naturally ONE level per press: nodes revealed by
    -- this pass aren't in the tree we just walked, so chasing them would take
    -- another L — which is the bound we want. Resolving a whole subtree
    -- speculatively is the churn eligible() warns about.
    local waiting = 0
    model.walk(st.roots, function(n)
      if not n.state.loaded and n._lazy then
        local fired = recurse_into(n, function()
          n.state.expanded = true
          waiting = waiting - 1
          if waiting == 0 and vim.api.nvim_win_is_valid(st.handle.win) then
            refresh(node and node.id)
          end
        end)
        if fired then
          waiting = waiting + 1
        end
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
  ---@param lnum integer
  local function in_docstring(lnum)
    local res = st.result
    return res and res.doc_start ~= nil and lnum >= res.doc_start and lnum <= res.doc_end
  end

  -- Locate a param's definition line inside the rendered docstring section.
  -- Docstring formats vary — numpy/loguru ("name : type"), google
  -- ("name: desc" / "name (type):"), sphinx (":param name:") — so try
  -- definition-shaped patterns across the whole section first and only then
  -- settle for a whole-word mention (prose references the param long before
  -- the Parameters block defines it).
  ---@param name string
  ---@return integer? lnum
  local function find_param_line(name)
    local res = st.result
    if not res.doc_start then
      return nil
    end
    local esc = vim.pesc(name)
    local patterns = {
      "^%s*%*?%*?" .. esc .. "%s*[:(]", -- name : type / name(type): / **kwargs :
      "^%s*:param%s+[^:]-" .. esc .. "%s*:", -- :param name: / :param type name:
      "^%s*%*?%*?" .. esc .. "%f[%W]", -- line opens with the bare name
      "%f[%w]" .. esc .. "%f[%W]", -- any whole-word mention
    }
    for _, pat in ipairs(patterns) do
      for lnum = res.doc_start, res.doc_end do
        if res.lines[lnum]:find(pat) then
          return lnum
        end
      end
    end
    return nil
  end

  map(km.docstring, function()
    if st.show_help then
      return
    end
    local doc = st.opts.docstring
    if not doc or doc == "" then
      vim.notify("typescope: no docstring available", vim.log.levels.INFO)
      return
    end
    if not st.opts.docstring_pos then
      vim.notify("typescope: docstring section disabled (ui.docstring = false)", vim.log.levels.INFO)
      return
    end
    local lnum = vim.api.nvim_win_get_cursor(st.handle.win)[1]
    if in_docstring(lnum) then
      -- second press from inside: fold back to the first paragraph and
      -- return to the row we came from (mirrors the help overlay's round trip)
      st.opts.docstring_expanded = false
      refresh(st.doc_return_id)
      return
    end
    local node = node_under_cursor()
    st.doc_return_id = node and node.id or nil
    st.opts.docstring_expanded = true
    -- ledger: fold the detail block before measuring, or the CursorMoved
    -- that our jump fires re-renders without it and shifts every doc line
    st.opts.detail_id = nil
    refresh()
    -- hovering a param jumps to where the docstring defines it; sub-items
    -- resolve upward since the docstring documents top-level params. That
    -- param is the first param-kind node on the id path — the root for
    -- plain calls, but one level down for overload groups ("overloadN.sink"
    -- — the group row is the callable itself, not a param)
    local target = st.result.doc_start
    if node then
      local prefix
      for seg in node.id:gmatch("[^.]+") do
        prefix = prefix and (prefix .. "." .. seg) or seg
        local n = model.find(st.roots, prefix)
        if n and n.kind == "param" then
          target = find_param_line(n.name) or target
          break
        end
      end
    end
    if target then
      vim.api.nvim_win_set_cursor(st.handle.win, { target, 0 })
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
        -- same 80ms gate as the spinner: a cache-served run finishes
        -- synchronously and a one-frame flash of bars would read as a glitch.
        -- The repaint is what starts the animation AT ALL: flipping to llm
        -- mode above changed no pixels, so nothing on screen is drawn as
        -- pending yet (38c).
        refresh()
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
      -- repaint either way. A run that filled NOTHING still cleared every
      -- leaf's pending flag, and the placeholder bars it painted at the start
      -- sit there until something repaints them. Not an edge case: a retry
      -- re-asks only the leaves that whiffed last time, so "filled nothing"
      -- is the ordinary outcome of pressing E again on a leaf the model has
      -- no idea about (Tony's **kwargs).
      refresh()
      if not ok and err then
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
      -- no refresh here: batch repaints ride the examples module's landed
      -- subscription (40u) — one path for this float's own batches and a
      -- previous open's late ones alike
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
  local function close()
    stop_clock()
    args.on_close()
  end
  map(km.close, close)
  map("<Esc>", close)

  -- j/k jump between interactive rows — params and expandable sub-items —
  -- skipping display-only lines (detail blocks, wrapped continuations,
  -- header/rule). Past the last node they fall back to plain movement so
  -- the docstring section stays reachable and scrollable. Inside the
  -- docstring it's all plain movement: node-jumping there made k bounce
  -- from mid-prose back to the ledger (every doc line is "skippable").
  local function jump(dir)
    if st.show_help then
      vim.cmd("normal! " .. (dir == 1 and "j" or "k"))
      return
    end
    local win = st.handle.win
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    if in_docstring(lnum) then
      vim.cmd("normal! " .. (dir == 1 and "j" or "k"))
      return
    end
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
          st.opts.detail_all = nil -- the peek ends the moment you move off
          refresh(id)
        end
      end,
    })
  end

  st.result = render.render(st.roots, st.opts)

  return { opts = st.opts, refresh = refresh, generate = generate }
end

return M
