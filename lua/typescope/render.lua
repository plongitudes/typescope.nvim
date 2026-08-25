---@class typescope.Highlight
---@field line integer 0-indexed
---@field col_start integer byte offset
---@field col_end integer byte offset
---@field group string

---@class typescope.Injection
---@field line integer 0-indexed
---@field col_start integer byte offset where the VISIBLE slice starts
---@field text string source snippet to highlight with the language's TS parser
---@field mode "replace"|"overlay" replace: syntax colors supplant the base block group (so bold/italic from semantic groups don't bleed through); overlay: both apply (examples keep their dim styling)
---@field from integer byte offset into `text` of the slice actually on screen
---@field to integer exclusive end of that slice

---@class typescope.RenderResult
---@field lines string[]
---@field highlights typescope.Highlight[]
---@field ts_injections typescope.Injection[] annotation/default/example spans for real syntax highlighting
---@field line_to_node table<integer, string> 1-indexed line -> node id (continuation lines included)
---@field width integer display width of the widest line
---@field doc_start? integer first line of the docstring section (1-indexed, content only)
---@field doc_end? integer last line of the docstring section

---@class typescope.RenderOpts
---@field style typescope.Charset
---@field max_width integer resolved columns (callers use config.resolved_max_width)
---@field window_width? integer inner width the float ALREADY has; content is laid out to at least it (rules stretch to it, pending bars reach it)
---@field layout? "tree"|"table"|"ledger" flowing segments (default) vs column grid (U5) vs one-line rows + detail block (U6)
---@field align? "left"|"right" name column alignment (default left, tree layout)
---@field detail_id? string ledger layout: node whose row expands into a detail block
---@field detail_all? boolean ledger layout: open EVERY row's detail block (L's transient peek, d1x)
---@field show_examples boolean
---@field example_kind "heuristic"|"llm"
---@field example_pending? fun(node: typescope.Node): boolean leaves whose LLM value is still coming (38c); injected so render stays pure
---@field example_reveal? fun(node: typescope.Node): number?, number?, integer? 0..1 through the fall, the wave phase it froze at, and the float width it froze at (38c)
---@field example_phase? number 0..1 position of the travelling wave through the pending bar (38c)
---@field lang? string treesitter language for injected snippet highlighting
---@field header? string one-line call shape shown above the tree
---@field header_active? string param name lit as active in the header (matches insert's signature block)
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

--- `text` is what lands on this line; `snippet`/`from` say what it is a piece
--- OF. A wrapped value and a half-uncovered one are both fragments — `dict[str,`
--- or `_t.UriTy` parse as nothing on their own, which is why a value that
--- wrapped, or one still emerging from under the wave, used to go flat grey
--- and then snap into color the instant it became whole (Tony, reveal.mov).
--- Parsing the WHOLE value and painting only the part on screen gives the
--- fragment the colors it will end up with. It also memoises: the snippet is
--- the same string every frame of a reveal, where per-frame fragments were a
--- fresh cache key each time.
---@param text string
---@param group? string base highlight group
---@param inject? "replace"|"overlay" span is a source snippet for real TS highlighting
---@param snippet? string full source `text` is a slice of (defaults to `text`)
---@param from? integer byte offset of `text` within `snippet` (defaults to 0)
function Line:add(text, group, inject, snippet, from)
  if text == "" then
    return self
  end
  if group then
    table.insert(self.hls, { col_start = #self.text, col_end = #self.text + #text, group = group })
  end
  if inject then
    from = from or 0
    table.insert(self.inj, {
      col_start = #self.text,
      text = snippet or text,
      mode = inject,
      from = from,
      to = from + #text,
    })
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

--- Byte index of the longest prefix of `text` that fits in `cells` columns.
--- Unlike find_break_point this cuts wherever it must and counts real display
--- width — the caller is clipping an animation frame, not laying out prose,
--- and the run it is cutting is usually block glyphs (three bytes, one cell).
---@param text string
---@param cells integer
---@return integer byte index, 0 when not even one character fits
local function fit_prefix(text, cells)
  local at = vim.str_utf_pos(text)
  local used, last = 0, 0
  for i = 1, #at do
    local stop = (at[i + 1] or #text + 1) - 1
    local w = strwidth(text:sub(at[i], stop))
    if used + w > cells then
      break
    end
    used, last = used + w, stop
  end
  return last
end

local is_expandable = require("typescope.model").is_expandable

-- LuaJIT compiles these to machine instructions once localised; the wave calls
-- them per cell per frame, so this is the one place in the file where hoisting
-- them off the `math` table is worth the two lines.
local sin = math.sin
local floor = math.floor
-- separate statements ON PURPOSE: `local floor, round = math.floor, ... floor`
-- binds the closure's `floor` to the GLOBAL (nil), because Lua evaluates the
-- whole rhs before either local exists
local function round(v)
  return floor(v + 0.5)
end
local PI = math.pi

-- The shape that travels through the placeholder bar while a leaf waits, and
-- that the landed value emerges from under. A Tukey-windowed sine: position is
-- NORMALISED (t = cell/(count-1)), so WAVE_FREQ oscillations span whatever
-- width the bar happens to be, and the sine taper at each end fades it to
-- nothing instead of chopping it off mid-crest.
--
-- This replaced a fixed 14-entry lookup table, which had two faults the shape
-- of the value exposed. It TILED: a 98-char value got seven wavelengths and
-- came out in seven chunks. And it could only move in whole cells — one step
-- per WAVE_PERIOD_MS/#WAVE = 100ms, measured at 11 changed frames per 60,
-- which read as judder. A continuous wave changes some cell's level every
-- frame: 60 of 60.
--
-- Brightness tracks height (see highlights.lua), so a cell rising through the
-- wave lights up as it grows and the highlight groups stay static.
local WAVE_FREQ = 3.0 -- oscillations across the bar, at ANY width
-- Fraction of total width spent tapering, split per end. It was 0.4 — 5.4
-- cells of fade at each end of a 28-cell bar — and the first four columns
-- never got above rung 2 at any phase, so the bar looked like it began five
-- columns right of where it does. The value's first character lands in column
-- one, which made the whole thing arrive left of where the eye had been
-- watching (Tony, reveal.mov). At 0.10 the fade is 1.4 cells: column two
-- already reaches rung 7, so the edge softens without moving. The trailing end
-- gets the same short taper and ends nearly square, which is the trade.
local WAVE_ALPHA = 0.30
local WAVE_STEPS = 8 -- ladder rungs; 8 reads as a curve where 5 read as steps
-- Minimum bar width. Below this there is less than one wavelength to look at,
-- so a narrow float still gets a bar worth watching.
local PENDING_CELLS = 28
-- charset fallback matching the ladder's own `opts.style and ... or` idiom —
-- LadderOpts.style is optional
local DEFAULT_BAR = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

--- Fifth element of a tail segment: the things only some segments carry.
---@class typescope.SegmentExtra
---@field clip boolean? overflow is cut off at the line's edge instead of wrapping
---@field snippet string? full source the segment's text is a slice of
---@field from integer? byte offset of the segment's text within `snippet`

-- Every cell of an animating row clips. A pending bar or a falling one is a
-- picture of a single value, and a picture that wraps is two pictures: the
-- 98-cell reveal of `returns` came out as two stacked waves mid-flight and
-- then re-flowed into a different shape when it settled (Tony, reveal.mov).
-- Clipped, the row stays one line and the window uncovers the rest of it as
-- it opens — which is what the growing float was for. The second line is
-- allowed to pop in at the end, once the value is real text.
local CLIP = { clip = true }

---@param opts typescope.RenderOpts|typescope.LadderOpts
local function ladder_of(opts)
  return opts.style and opts.style.bar or DEFAULT_BAR
end

--- Group for a bar cell at ladder rung `i`. Named here like every other group
--- in this file; highlights.lua defines one per rung, dim → bright.
---@param i integer
local function rung_group(i)
  return "TypeScopeExamplePending" .. math.max(1, math.min(#DEFAULT_BAR, i))
end

--- Collapse a per-cell height list into segments, merging runs of equal height
--- so a 14-cell bar costs ~6 highlights rather than 14.
---@param heights integer[]
---@param ladder string[]
---@return { [1]: string, [2]: string?, [3]: string?, [4]: boolean? }[]
local function bar_segments(heights, ladder)
  local segs, run, run_h = {}, {}, nil
  local function flush()
    if #run > 0 then
      table.insert(segs, { table.concat(run), rung_group(run_h), nil, nil, CLIP })
      run = {}
    end
  end
  for _, h in ipairs(heights) do
    if h ~= run_h then
      flush()
    end
    run_h = h
    -- height 0 is empty space, not the shortest rung: it is what lets the
    -- taper fade to nothing at the ends and separates crest from crest
    table.insert(run, h >= 1 and ladder[math.min(#ladder, h)] or " ")
  end
  flush()
  return segs
end

--- The wave's heights (0..WAVE_STEPS) across `count` cells at this phase.
--- Normalised in position, so the same shape fills any width.
---@param phase number 0..1, one full scroll
---@param count integer
---@param alpha number? taper fraction, defaults to WAVE_ALPHA
---@param freq number? oscillations across the run, defaults to WAVE_FREQ
---@return integer[]
local function wave_heights(phase, count, alpha, freq)
  alpha = alpha or WAVE_ALPHA
  freq = freq or WAVE_FREQ
  local half = alpha / 2
  local turns = phase * 2 * PI
  local heights = {}
  for i = 1, count do
    local t = count > 1 and (i - 1) / (count - 1) or 0
    -- Quarter sine, not raised cosine. Both run 0 -> 1 across the taper
    -- and both meet the plateau flat, but the raised cosine is an S: it
    -- leaves the outermost columns near nothing for the first third of the
    -- taper (at alpha 0.3 the first one peaked at rung 1 of 8) and does all
    -- its climbing in the middle. Those columns read as unpainted, which is
    -- most of why the bar looked like it began further in than it does.
    --
    -- A sine is steepest at the very edge and eases only as it approaches
    -- the plateau, so the lower half of the climb is near-linear: that same
    -- column now peaks at rung 3, and the taper's midpoint at 6 rather
    -- than 4. Nothing else moves — this is exactly the square root of the
    -- old envelope (the amplitude taper where that was the power one), so
    -- the taper keeps its width and its smooth join.
    local envelope = 1.0
    if t < half then
      envelope = sin(PI / 2 * (t / half))
    elseif t > (1 - half) then
      envelope = sin(PI / 2 * ((1 - t) / half))
    end
    -- unipolar: 0..1 rather than -1..1, so the trough is empty and the crest
    -- is full rather than the bar sitting at half height at rest
    local unipolar = 0.5 * (1 + sin(2 * PI * freq * t + turns))
    heights[i] = round(unipolar * envelope * WAVE_STEPS)
  end
  return heights
end

--- The pending bar's wave, continued across `span` cells.
---
--- wave_heights normalises position, so asking it for a wider run STRETCHES
--- the shape — three oscillations either way, just longer ones. That is wrong
--- here: the bar the eye was watching had a wavelength, and the frame it
--- freezes on must not change it. Scaling frequency and taper by the same
--- factor as the span keeps both fixed IN CELLS, so cells 1..PENDING_CELLS
--- come back bit-identical to what the bar was showing and the extra cells
--- simply continue the same wave.
---
--- Not exactly identical at the right end: the bar's own trailing taper sat
--- at the float's right edge, and in a longer run the taper has moved out to
--- the value's real end, so those cells rise a few rungs on the landing frame.
--- That surge is the deliberate cost of keeping the wavelength — the
--- alternative, pinning the taper to the window edge as it slides, tripled the
--- highlight runs per frame (817 -> 2767 on a 48-leaf ledger) for a subtler
--- join. It also lands where the window is about to open, which is the least
--- conspicuous place on the row for it to happen.
---@param phase number
---@param span integer
---@param base integer cells the pending bar occupied — the wavelength to keep
---@return integer[]
local function frozen_wave(phase, span, base)
  if span <= base then
    return wave_heights(phase, base)
  end
  local k = (span - 1) / (base - 1)
  return wave_heights(phase, span, WAVE_ALPHA / k, WAVE_FREQ * k)
end

--- Is this leaf's LLM value still coming? Only llm mode has a pending state;
--- a heuristic value is final the moment it exists.
---@param node typescope.Node
---@param opts typescope.RenderOpts|typescope.LadderOpts
---@return boolean
local function is_pending(node, opts)
  return opts.example_kind == "llm" and opts.example_pending ~= nil and opts.example_pending(node)
end

--- The value a node's example shows, if it has one at all.
---@param node typescope.Node
---@param opts typescope.RenderOpts|typescope.LadderOpts
---@return string?
local function example_for(node, opts)
  if not opts.show_examples then
    return nil
  end
  return node.example[opts.example_kind] or node.example.heuristic
end

-- (example_style used to live here, choosing between a flat pending group and
-- the overlaid settled one. Nothing calls it any more: a pending row is a bar,
-- never text, so the only style left is the settled one — plain
-- TypeScopeExample with syntax colors overlaid, inline at the end of
-- example_segments.)

-- How far the blocks have fallen at the end of the reveal: a full-height cell
-- has to reach zero exactly as the animation finishes.
local FALL_DISTANCE = #DEFAULT_BAR

--- The landed value emerging from under the travelling wave. The wave FREEZES
--- where it stood when the value arrived, then every block falls — like the
--- peak dots on an equalizer, accelerating under gravity, all released at
--- once. A cell that reaches zero uncovers the character beneath it, so the
--- value surfaces in the wave's own shape: troughs first, crests last.
---
--- Cells run to max(value, one wavelength) so nothing jumps at the moment of
--- landing; blocks past the end of the value simply fall away and leave
--- nothing. That also makes a MISS graceful — no value at all just means the
--- bar drains off the line instead of vanishing between frames.
---
--- The wave covers the WHOLE value, tail included. It used to stop at the
--- bar's width, on the reasoning that a longer value jumps the line wider the
--- instant it lands no matter what the wave does — so occluding the tail only
--- added unreadability on top of a jump it could not prevent. Two things
--- changed. The float now grows into its new width over ~400ms instead of
--- snapping (interact.lua), so there IS no jump to concede to; and the tail
--- was arriving as bare settled text on the first reveal frame, which is what
--- made roughly 40% of a long value appear between two frames.
---
--- The older objection — that tiling the wave across the value put a hole
--- every 14 cells and broke a 98-char example into seven chunks — was against
--- the fixed lookup table this replaced. frozen_wave continues one wave at a
--- constant wavelength rather than repeating a fixed-length one, so there are
--- no seams to fall between.
---@param value string? nil for a MISS: bar falls, nothing underneath
---@param progress number 0..1
---@param phase number the wave phase this froze at
---@param ladder string[]
---@param base integer cells the pending bar filled, so the fall starts its width
---@return { [1]: string, [2]: string?, [3]: string?, [4]: boolean? }[]
local function reveal_segments(value, progress, phase, ladder, base)
  -- `at` is kept as well as `chars`: it is already the 1-based byte offset of
  -- every character, which is what an injection slice needs, so carrying it
  -- costs nothing where a second parallel array would cost one store per cell
  -- per row per frame
  local chars, at, cells = {}, nil, 0
  if value then
    at = vim.str_utf_pos(value)
    cells = #at
    for i = 1, cells do
      chars[i] = value:sub(at[i], (at[i + 1] or #value + 1) - 1)
    end
  end
  -- keep the bar's own width until the blocks drain it away: the value never
  -- has to shove the line wider, it's uncovered inside a space already held
  local total = math.max(cells, base)
  -- the same heights the pending bar was showing the frame before this one,
  -- continued across the value's full width, so the fall starts from exactly
  -- where the eye left it
  local frozen = frozen_wave(phase, total, base)
  -- Released with a little initial velocity rather than from rest. Pure
  -- gravity (progress²) spends its first 40% moving less than one rung, and
  -- with only eight rungs to quantise into that reads as nothing happening at
  -- all; this keeps the brief peak-hold an equalizer has, then accelerates.
  local fallen = FALL_DISTANCE * progress * (0.6 + 0.4 * progress)

  -- merge neighbours that render the same way: a run of text, a run of blocks
  -- at one rung, or a run of held-open cells
  local segs, keys, run, run_key, run_rung, run_at = {}, {}, {}, nil, nil, 1
  local function flush()
    if #run == 0 then
      return
    end
    if run_key == "text" then
      -- an uncovered run injects as a SLICE of the whole value, not as the
      -- fragment it looks like: `_t.UriTy` parses as nothing, so painting it
      -- on its own left the value grey until the frame it became whole and
      -- then flipped it to full color in one step (Tony, reveal.mov). Sliced,
      -- every character arrives already wearing the color it will keep.
      table.insert(segs, {
        table.concat(run),
        "TypeScopeExample",
        "overlay",
        nil,
        { clip = true, snippet = value, from = at[run_at] - 1 },
      })
    elseif run_key == "blank" then
      table.insert(segs, { table.concat(run), nil, nil, nil, CLIP })
    else
      table.insert(segs, { table.concat(run), rung_group(run_rung), nil, nil, CLIP })
    end
    keys[#segs] = run_key
    run = {}
  end
  for i = 1, total do
    local height = frozen[i] - fallen
    local key, rung, text
    if height <= 0 then
      -- A drained cell with no character under it holds its column with a
      -- SPACE. Emitting nothing pulled every block to its right one cell left,
      -- so a value shorter than the bar (or a MISS, with nothing under any of
      -- it) had its frozen wave creep leftwards the whole way down — the eye
      -- reads that as the wave travelling again, which is the one thing
      -- freezing it was meant to stop. Values longer than the bar never showed
      -- the artifact: every cell has a character, so nothing ever collapsed.
      key, text = chars[i] and "text" or "blank", chars[i] or " "
    else
      rung = math.max(1, math.min(#ladder, math.ceil(height)))
      key, text = "bar", ladder[rung]
    end
    if key ~= run_key or rung ~= run_rung then
      flush()
      run_at = i
    end
    run_key, run_rung = key, rung
    table.insert(run, text)
  end
  flush()
  -- held-open cells only matter BETWEEN things; past the last block or
  -- character they are trailing whitespace, and nothing to their right can
  -- shift. Dropping them keeps the row's measured width honest.
  while #segs > 0 and keys[#segs] == "blank" do
    local last = #segs
    segs[last], keys[last] = nil, nil
  end
  return segs
end

--- Segments for a node's example: none when there's nothing to show, one for a
--- settled value, many while waiting or mid-fall — alternating runs of block
--- and (mid-fall) uncovered text in real syntax colors. More than one group is
--- the point: one can't carry both, and keeping the whole thing dim until the
--- wave finished would just move the pop-in to the end of it.
--- NOT atomic, unlike the badges and origin tags around it. An atomic segment
--- jumps whole to the next line rather than splitting, which for a value wider
--- than the row left `e.g.` alone on a line of its own with the value hanging
--- underneath it — a whole line spent on two characters, in a float whose
--- point is compactness (Tony's call, reveal.mov f804->f805). It also
--- disagreed with the animation right before it: the clipped falling frame
--- starts the value straight after `e.g. `, and settling then moved it. Split
--- like ordinary text, the two frames agree and nothing moves vertically.
---@param node typescope.Node
---@param opts typescope.RenderOpts|typescope.LadderOpts
---@param fill boolean? caller wraps segments (flow/wrap_segs) and can size a wave to the row
---@return { [1]: string, [2]: string?, [3]: string?, [4]: boolean? }[]
local function example_segments(node, opts, fill)
  local value = example_for(node, opts)
  local ladder = ladder_of(opts)
  local phase = opts.example_phase or 0

  --- One segment standing for a wave whose width isn't known here. Only the
  --- wrapper knows where on the row the example starts, and the wave has to
  --- run from there to the float's right edge — a bar that stops short of it
  --- has to grow to the edge on the frame the value lands, which is a jump
  --- across a third of the row (Tony, reveal.mov f747->f748). The wrapper
  --- calls back with the cell count once it knows it.
  ---@param make fun(cells: integer): table[]
  ---@param edge integer? right edge to run out to, if not the float's current one
  local function sized(make, edge)
    return { { "", nil, nil, nil, { fill = make, edge = edge, clip = true } } }
  end

  if is_pending(node, opts) then
    -- EVERY waiting row is a bar, whether or not a heuristic could stand in.
    -- It used to be two states — a bar for leaves no heuristic matched, the
    -- heuristic itself pulsing for the rest — and the two have to become one
    -- thing at the landing frame. They didn't: the pulsing rows grew 28 cells
    -- of bar between two frames, out of nothing (Tony, 38c video, f931->f932).
    -- Losing the heuristic during the wait is the price; a MISS now reveals it
    -- under the falling bar instead of leaving it untouched, which is a
    -- better answer for the row anyway.
    --
    -- The bar also holds the line open. Without it a leaf that ends up with no
    -- example at all has no example line, and the value doesn't so much arrive
    -- as make the block grow a line under the cursor.
    if fill then
      return sized(function(cells)
        return bar_segments(wave_heights(phase, cells), ladder)
      end)
    end
    return bar_segments(wave_heights(phase, PENDING_CELLS), ladder)
  end

  local progress, frozen, frozen_width = nil, 0, nil
  if opts.example_reveal then
    progress, frozen, frozen_width = opts.example_reveal(node)
  end
  if progress and progress < 1 then
    if fill then
      -- The same cell count the pending bar had, so the frozen wave the blocks
      -- fall from is the one that was on screen the frame before — and it
      -- KEEPS that count for the whole fall. The landed values are what widen
      -- the float, so a wave measured against the float's current edge is
      -- measured against a moving one, and frozen_wave rescales its wavelength
      -- to the new run every frame: the wave stretches as the window opens.
      return sized(function(cells)
        return reveal_segments(value, progress, frozen or 0, ladder, cells)
      end, frozen_width)
    end
    return reveal_segments(value, progress, frozen or 0, ladder, PENDING_CELLS)
  end
  if not value then
    return {}
  end
  -- settled: the value keeps str/int/dict colors like code anywhere else
  return { { value, "TypeScopeExample", "overlay" } }
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
      table.insert(result.ts_injections, {
        line = lnum - 1,
        col_start = inj.col_start,
        text = inj.text,
        mode = inj.mode,
        from = inj.from,
        to = inj.to,
      })
    end
    result.width = math.max(result.width, line.width)
  end

  -- Wrap the tail segments (type/default/example) of a row across
  -- continuation lines with a hanging indent at the annotation column.
  ---@param line typescope.Line current line holding prefix + name padding
  ---@param cont_prefix string chrome carried onto continuation lines
  ---@param cont_pad integer spaces after cont_prefix to reach the annotation column
  ---@param segments { [1]: string, [2]: string?, [3]: string?, [4]: boolean?, [5]: typescope.SegmentExtra? }[]
  ---@param node_id string
  local function flow(line, cont_prefix, cont_pad, segments, node_id)
    -- how wide a FRESH continuation line already is before any content: the
    -- chrome plus the pad. Pushing an over-long atomic segment down a line only
    -- helps while the current line is wider than this; test it against cont_pad
    -- alone and a line that has just been continued still reads as "wider than
    -- the pad" (the chrome counts), so an atomic segment too big to fit even on
    -- an empty continuation line asks for another one forever. render.render
    -- then never returns — a hung editor, not a mangled layout.
    local cont_width = strwidth(cont_prefix) + cont_pad

    local function continuation()
      emit(line, node_id)
      line = new_line()
      line:add(cont_prefix, "TypeScopeChrome")
      line:add(string.rep(" ", cont_pad))
      return line
    end

    -- How many cells a wave gets on this row: from wherever it starts out to
    -- the float's own right edge, so the pending bar is already as wide as the
    -- landed value's will be and the landing frame moves nothing sideways.
    -- Before the float has a width — its very first paint — there is no edge
    -- to reach for and the fixed bar stands in for one frame.
    local function wave_cells(edge)
      edge = math.min(opts.max_width, edge or opts.window_width or 0)
      return math.max(PENDING_CELLS, edge - line.width)
    end

    -- once a clipping segment has run into the edge, everything after it
    -- would sit past the same edge; emitting it would wrap the very line the
    -- clip exists to keep whole
    local clipped = false
    local function place(seg)
      local text, group = seg[1], seg[2]
      local inject = seg[3]
      -- atomic segments (badges, origin tags, indicators) never split
      -- mid-word — they jump whole to the next line instead
      local atomic = seg[4]
      local extra = seg[5]
      -- Splitting no longer costs the injection. What lands on a line is a
      -- SLICE of a snippet, so a continuation carrying `dict[str,` is painted
      -- from the colors the whole annotation parses to, and a reveal's
      -- half-uncovered value from the colors the whole value parses to.
      local snippet = (extra and extra.snippet) or text
      local from = (extra and extra.from) or 0
      while text ~= "" do
        local avail = opts.max_width - line.width
        if strwidth(text) <= avail then
          line:add(text, group, inject, snippet, from)
          text = ""
        elseif extra and extra.clip then
          local cut = fit_prefix(text, avail)
          line:add(text:sub(1, cut), group, inject, snippet, from)
          text, clipped = "", true
        elseif (atomic or avail < 8) and line.width > cont_width then
          -- push the whole segment down a line
          line = continuation()
        else
          -- it does not fit even on a line of its own: split it after all,
          -- atomic or not. A value chopped across two rows is worse than one
          -- kept whole, and better than every other outcome available here.
          local cut = math.max(1, find_break_point(text, avail))
          line:add(text:sub(1, cut), group, inject, snippet, from)
          local rest = text:sub(cut + 1)
          local kept = rest:gsub("^%s+", "")
          -- the stripped leading blank is still part of the snippet, so the
          -- next piece's offset has to step over it too
          from = from + cut + (#rest - #kept)
          text = kept
          line = continuation()
        end
      end
    end

    for _, seg in ipairs(segments) do
      if clipped then
        break
      end
      local extra = seg[5]
      if extra and extra.fill then
        -- sized here and not by the caller: line.width is only final once
        -- everything to the left of the wave has been placed
        for _, sub in ipairs(extra.fill(wave_cells(extra.edge))) do
          if clipped then
            break
          end
          place(sub)
        end
      else
        place(seg)
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
    local marker = is_expandable(node) and (node.state.expanded and style.expanded or style.collapsed) or style.leaf
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
    local example_segs = example_segments(node, opts, true)
    if #example_segs > 0 then
      table.insert(segments, { "  ", nil })
      -- overlay: examples are hypothetical values, they keep their dim
      -- TypeScopeExample styling underneath the syntax colors
      vim.list_extend(segments, example_segs)
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
    result.doc_start = #result.lines + 1
    for _, doc_line in ipairs(vim.split(vim.trim(text), "\n")) do
      if doc_line == "" then
        emit(new_line(), nil)
      else
        emit_prose(doc_line, "TypeScopeDocstring")
      end
    end
    result.doc_end = #result.lines
  end

  local has_doc = opts.docstring ~= nil
    and opts.docstring ~= ""
    and opts.docstring_pos ~= nil
    and opts.docstring_pos ~= false
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
    -- colors align with the insert ladder's signature block (Tony,
    -- 2026-08-06): yellow reserved for the callable + parens, params in
    -- param color with the active one lit, the return as a real type with
    -- syntax injection. Elision marks (`=…`, trailing `…`) render as chrome
    -- — same as ledger rows' default marks — superseding the 2026-08-01
    -- dim-at-header-hue call, which assumed a single-hue header.
    local hline = new_line()
    -- we authored the format in resolve (name(tok, tok) -> ret [i/n]), so
    -- this parse can't miss; the plain fallback is pure defense
    local badge = header:match("%s(%[%d+/%d+%])$")
    local sig = badge and header:sub(1, #header - #badge - 1) or header
    -- non-greedy params: the FIRST `) -> ` closes the call, so a callable
    -- return like `(int) -> str` stays whole (tokens never contain parens)
    local fn_name, params, ret = sig:match("^([^(]+)%((.-)%) %-> (.*)$")
    if not fn_name then
      fn_name, params = sig:match("^([^(]+)%((.-)%)$")
    end
    if fn_name then
      hline:add(fn_name, "TypeScopeHeader")
      hline:add("(", "TypeScopeHeader")
      local toks = params ~= "" and vim.split(params, ", ", { plain = true }) or {}
      for i, tok in ipairs(toks) do
        if tok == "*" or tok == "/" then
          hline:add(tok, "TypeScopeKeyword")
        elseif tok == "…" then
          hline:add(tok, "TypeScopeChrome")
        else
          local name, mark = tok:match("^(.-)(=…)$")
          name = name or tok
          hline:add(name, name == opts.header_active and "TypeScopeActive" or "TypeScopeParam")
          if mark then
            hline:add(mark, "TypeScopeChrome")
          end
        end
        if i < #toks then
          hline:add(", ", "TypeScopeChrome")
        end
      end
      hline:add(")", "TypeScopeHeader")
      if ret then
        hline:add(" -> ", "TypeScopeChrome")
        hline:add(ret, "TypeScopeType", "replace")
      end
      if badge then
        hline:add(" " .. badge, "TypeScopeBadge")
      end
    else
      hline:add(header, "TypeScopeHeader")
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

      local example_segs = example_segments(node, opts)

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
            local clean = text:sub(cut, cut):match("[%s,]") ~= nil
              or text:sub(cut + 1, cut + 1):match("%s") ~= nil
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
      local detail = opts.detail_all or node.id == opts.detail_id
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
      local evaluated_visible = node.evaluated and not (node.evaluated_on_expand and not node.state.expanded)
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
      local def_w = default_text and (4 + strwidth(default_text)) or (node.default and not detail and 5 or 0)
      if strwidth(type_text) + def_w > budget then
        default_text = nil -- degrade the default before touching the type
        def_w = node.default and not detail and 5 or 0
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
        line:add("  = ", "TypeScopeChrome")
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
          -- overlay: real syntax colors over the dim ≈ base, kept even if the
          -- value wraps (flow slices the injection with it)
          table.insert(segs, { node.evaluated, "TypeScopeEvaluated", "overlay" })
          detail_line(segs)
        end
        local info = {}
        if node.default then
          table.insert(info, { "= ", "TypeScopeChrome" })
          table.insert(info, { node.default, "TypeScopeDefault", "replace" })
        end
        local example_segs = example_segments(node, opts, true)
        if #example_segs > 0 then
          table.insert(info, { (#info > 0 and "   " or "") .. "e.g. ", "TypeScopeHint" })
          vim.list_extend(info, example_segs)
        end
        if node.origin then
          table.insert(
            info,
            { (#info > 0 and "   " or "") .. style.inherit .. node.origin, "TypeScopeHint", nil, true }
          )
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

  -- Separators stretch to the final content width, known only now — but never
  -- back in from a width they have already reached. The window is monotonic
  -- (interact keeps st.width at its high-water mark), and a rule that shrank
  -- while the frame around it stayed put read as the whole float twitching:
  -- landing a long value re-flowed its row onto two shorter ones, and both
  -- rules snapped in by a dozen columns on that frame (Tony, reveal.mov).
  local rule_width = math.max(4, result.width, opts.window_width or 0)
  for _, lnum in ipairs(separators) do
    local bar = string.rep(style.rule, rule_width)
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
---@field example_pending? fun(node: typescope.Node): boolean leaves whose LLM value is still coming (38c); injected so render stays pure
---@field example_reveal? fun(node: typescope.Node): number?, number?, integer? 0..1 through the fall, the wave phase it froze at, and the float width it froze at (38c)
---@field example_phase? number 0..1 position of the travelling wave through the pending bar (38c)
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
  ---@param shape_text? string
  ---@return { [1]: string, [2]: string?, [3]: string?, [4]: boolean? }[]
  local function segs_for(shape_text)
    local segs = {}
    -- extras ride along: without them wrap_segs never sees a wave's request to
    -- be sized to the row, or an animating example's request not to wrap, and
    -- silently renders the empty placeholder instead of the wave
    local function seg(text, group, inject, atomic, extra)
      table.insert(segs, { text, group, inject, atomic, extra })
    end
    seg(node.name, "TypeScopeActive")
    seg(": ", "TypeScopeChrome")
    seg(
      type_text,
      node.evaluated and type_text == node.evaluated and "TypeScopeEvaluated" or "TypeScopeType",
      "replace"
    )
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
    -- fill=true, though LadderOpts carries no window_width: the insert ladder
    -- is sized to its content on every keystroke rather than held at a
    -- high-water mark, so there is no edge to reach for and wave_cells falls
    -- back to the fixed bar. Opting in costs nothing and means the two
    -- wrappers stay the same shape.
    local example_segs = example_segments(node, opts, true)
    if #example_segs > 0 then
      seg("   e.g. ", "TypeScopeHint")
      for _, es in ipairs(example_segs) do
        seg(es[1], es[2], es[3], es[4], es[5])
      end
    end
    return segs
  end

  -- wrap segments into width-bounded lines with a hanging indent (mirrors
  -- render()'s flow: a split piece keeps its injection as a slice of the whole
  -- snippet, and atomic segments jump whole to the next line)
  --- The ladder's own wrapper. Same contract as render's flow(), including the
  --- segment extras: an animating example clips to one line instead of
  --- wrapping into two pictures of itself, and a split piece keeps its
  --- injection as a slice of the whole snippet.
  ---@param segs { [1]: string, [2]: string?, [3]: string?, [4]: boolean?, [5]: typescope.SegmentExtra? }[]
  ---@param cont_indent integer
  local function wrap_segs(segs, cont_indent)
    local lines = {}
    local line = new_line()
    local function continuation()
      table.insert(lines, line)
      line = new_line()
      line:add(string.rep(" ", cont_indent))
    end
    local clipped = false
    local function wave_cells(edge)
      edge = math.min(opts.max_width, edge or opts.window_width or 0)
      return math.max(PENDING_CELLS, edge - line.width)
    end
    local function place(seg)
      local text, group, inject, atomic = seg[1], seg[2], seg[3], seg[4]
      local extra = seg[5]
      local snippet = (extra and extra.snippet) or text
      local from = (extra and extra.from) or 0
      while text ~= "" do
        local avail = opts.max_width - line.width
        if strwidth(text) <= avail then
          line:add(text, group, inject, snippet, from)
          text = ""
        elseif extra and extra.clip then
          line:add(text:sub(1, fit_prefix(text, avail)), group, inject, snippet, from)
          text, clipped = "", true
        elseif (atomic or avail < 8) and line.width > cont_indent then
          continuation()
        else
          local cut = math.max(1, find_break_point(text, avail))
          line:add(text:sub(1, cut), group, inject, snippet, from)
          local rest = text:sub(cut + 1)
          local kept = rest:gsub("^%s+", "")
          from = from + cut + (#rest - #kept)
          text = kept
          continuation()
        end
      end
    end
    for _, seg in ipairs(segs) do
      if clipped then
        break
      end
      local extra = seg[5]
      if extra and extra.fill then
        for _, sub in ipairs(extra.fill(wave_cells(extra.edge))) do
          if clipped then
            break
          end
          place(sub)
        end
      else
        place(seg)
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
      table.insert(
        result.highlights,
        { line = #result.lines - 1, col_start = hl.col_start, col_end = hl.col_end, group = hl.group }
      )
    end
    for _, inj in ipairs(l.inj) do
      -- from/to travel with the injection, exactly as render()'s emit does: a
      -- wrapped or clipped segment puts only a SLICE of the snippet on this
      -- line, and float.inject_highlights needs both ends to place the parsed
      -- spans against it. Dropped, they default to the whole snippet and the
      -- extmarks run off the end of the line (Invalid 'col': out of range).
      table.insert(result.ts_injections, {
        line = #result.lines - 1,
        col_start = inj.col_start,
        text = inj.text,
        mode = inj.mode,
        from = inj.from,
        to = inj.to,
      })
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
    table.insert(
      result.highlights,
      { line = rule_lnum - 1, col_start = 0, col_end = #bar, group = "TypeScopeChrome" }
    )
  end
  return result
end

-- Exposed so test_render.lua section 13 can pin the contract directly: cells
-- in, a 1-based inclusive BYTE index out, caller strips the leading whitespace
-- from the remainder. Five call sites route through it and the asymmetry in
-- that contract is where both UTF-8 truncation defects came from, so it is
-- worth asserting on its own rather than only through a rendered tree.
--
-- (It previously also claimed to be here for the spike to hot-swap
-- experiments. Nothing ever did, and nothing does now.)
M._find_break_point = find_break_point

return M
