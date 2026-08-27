-- :TypeScope spike [style] — visual prototyping harness.
-- Opens the unified TypeScope float (header + tree + docstring sections)
-- with fixture trees, no LSP involved. Everything rendered here goes through
-- the production render.lua/float.lua path, so style decisions ship as-is.

local model = require("typescope.model")
local render = require("typescope.render")
local styles = require("typescope.styles")
local float = require("typescope.float")
local config = require("typescope.config")
local interact = require("typescope.interact")

local M = {}

-- hand-aligned fixture table: one field per line is unreadable
-- stylua: ignore
local function fixtures()
  return {
    {
      name = "dataclass",
      signature = "create_server(config: ServerConfig, timeout: float = 30.0) -> Response",
      roots = {
        model.new({
          name = "config",
          kind = "param",
          expanded = true,
          active = true,
          type = { raw = "ServerConfig", display = "ServerConfig", category = "dataclass" },
          children = {
            { name = "host", type = { display = "str", category = "builtin" }, example = { heuristic = '"localhost"' } },
            { name = "port", type = { display = "int", category = "builtin" }, example = { heuristic = "8080" } },
            { name = "debug", type = { display = "bool", category = "builtin" }, default = "False", example = { heuristic = "True" } },
            { name = "timeout_ms", type = { display = "int | None", category = "generic" }, default = "None", example = { heuristic = "None" } },
          },
        }),
        model.new({
          name = "timeout",
          kind = "param",
          type = { display = "float", category = "builtin" },
          default = "30.0",
          example = { heuristic = "30.0" },
        }),
        model.new({
          name = "returns",
          kind = "return",
          type = { raw = "Response", display = "Response", category = "dataclass" },
          children = {
            { name = "status", type = { display = "int", category = "builtin" }, example = { heuristic = "42" } },
            { name = "body", type = { display = "bytes", category = "builtin" } },
            { name = "headers", type = { display = "dict[str, str]", category = "generic" } },
          },
        }),
      },
    },
    {
      name = "pydantic (nested + wrap)",
      signature = "submit_job(job: PipelineJob) -> JobHandle",
      roots = {
        model.new({
          name = "job",
          kind = "param",
          expanded = true,
          type = { raw = "PipelineJob", display = "PipelineJob", category = "pydantic" },
          children = {
            { name = "name", type = { display = "str", category = "builtin" }, example = { heuristic = '"example"' } },
            {
              name = "handlers",
              type = {
                display = "dict[str, Callable[[Request, Session], Awaitable[Response | None]]]",
                category = "generic",
              },
            },
            {
              name = "retry",
              kind = "field",
              expanded = true,
              type = { raw = "RetryPolicy", display = "RetryPolicy", category = "pydantic" },
              children = {
                { name = "max_attempts", type = { display = "int", category = "builtin" }, default = "3", example = { heuristic = "42" } },
                { name = "backoff", type = { display = "float", category = "builtin" }, default = "2.0", example = { heuristic = "3.14" } },
              },
            },
            {
              name = "hooks",
              type = {
                display = "list[tuple[str, Callable[..., Awaitable[None]], int]]",
                category = "generic",
              },
              default = "[]",
            },
          },
        }),
        model.new({
          name = "returns",
          kind = "return",
          type = { raw = "JobHandle", display = "JobHandle", category = "pydantic" },
          children = {
            { name = "id", type = { display = "str", category = "builtin" }, example = { heuristic = '"a1b2c3d4"' } },
          },
        }),
      },
    },
    {
      name = "TypedDict (badges)",
      signature = "update_user(record: UserRecord) -> None",
      roots = {
        model.new({
          name = "record",
          kind = "param",
          expanded = true,
          type = { raw = "UserRecord", display = "UserRecord", category = "typeddict" },
          children = {
            { name = "email", type = { display = "str", category = "builtin" }, badge = "Required", example = { heuristic = '"user@example.com"' } },
            { name = "name", type = { display = "str", category = "builtin" }, example = { heuristic = '"example"' } },
            { name = "age", type = { display = "int | None", category = "generic" }, badge = "NotRequired", example = { heuristic = "None" } },
            { name = "tags", type = { display = "list[str] | tuple[str, ...]", category = "generic" }, badge = "NotRequired" },
          },
        }),
        model.new({
          name = "returns",
          kind = "return",
          type = { display = "None", category = "builtin" },
        }),
      },
    },
    {
      name = "Protocol (methods + unresolved)",
      signature = "mount(backend: StorageBackend, opaque: FrobnicatorHandle) -> None",
      roots = {
        model.new({
          name = "backend",
          kind = "param",
          expanded = true,
          type = { raw = "StorageBackend", display = "StorageBackend", category = "protocol" },
          children = {
            { name = "read", kind = "method", type = { display = "(path: str) -> bytes", category = "builtin" } },
            { name = "write", kind = "method", type = { display = "(path: str, data: bytes) -> None", category = "builtin" } },
            { name = "root", type = { display = "Path", category = "builtin" }, example = { heuristic = '"/tmp/example"' } },
          },
        }),
        model.new({
          name = "opaque",
          kind = "param",
          type = { raw = "FrobnicatorHandle", display = "FrobnicatorHandle", category = "unresolved" },
        }),
        model.new({
          name = "returns",
          kind = "return",
          type = { display = "None", category = "builtin" },
        }),
      },
    },
  }
end

---@class typescope.SpikeState
---@field fixture_idx integer
---@field style_idx integer
---@field show_examples boolean
---@field docstring_expanded boolean
---@field ts typescope.FloatHandle?
---@field fixtures table[]
local state = nil

-- Each style is showcased as a full visual package: tree chrome + a matching
-- float border. In the real config ui.style and ui.border stay independent;
-- this pairing exists only so the spike presents coherent identities.
local style_borders = {
  unicode = "single",
  rounded = "rounded",
  ascii = { "+", "-", "+", "|", "+", "-", "+", "|" },
  minimal = "none",
}

local function close_all()
  if not state then
    return
  end
  float.close(state.ts)
  state = nil
end

local function draw()
  local fixture = state.fixtures[state.fixture_idx]
  local style_name = styles.names[state.style_idx]
  local cfg = config.get()

  local max_width = config.resolved_max_width()
  local render_opts = {
    style = styles.get(style_name),
    max_width = max_width,
    align = cfg.ui.align,
    show_examples = state.show_examples,
    example_kind = "heuristic",
    lang = "python",
    header = fixture.signature,
    docstring = fixture.docstring
      or "Mock docstring for visual evaluation.\n\nLonger prose lives in the second paragraph, revealed with the d key.",
    docstring_expanded = state.docstring_expanded,
    docstring_pos = cfg.ui.docstring,
  }
  local result = render.render(fixture.roots, render_opts)

  local border = style_borders[style_name] or cfg.ui.border
  -- nvim rejects title/footer on borderless floats
  local borderless = border == "none"
  local width = math.min(max_width, math.max(result.width, 40))
  local height = math.min(cfg.ui.max_height, #result.lines)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  -- Dev harness: rebuild the float each redraw; detach the handle BEFORE
  -- closing — nvim_win_close fires WinClosed synchronously, and the teardown
  -- autocmd must see this as a redraw, not a user close.
  local old_ts = state.ts
  state.ts = nil
  float.close(old_ts)

  -- unified float (U1): header + tree + docstring sections in one window
  state.ts = float.open({
    lines = result.lines,
    highlights = result.highlights,
    ts_injections = result.ts_injections,
    lang = render_opts.lang,
    title = not borderless and (" typescope · %s · %s "):format(fixture.name, style_name) or nil,
    footer = not borderless and " ? help " or nil,
    relative = "editor",
    row = 2,
    col = col,
    width = width,
    height = height,
    border = border,
    enter = true,
  })

  -- Tree navigation (expand/collapse, examples, help, close) comes from the
  -- production interact layer; the spike only adds its harness keys on top.
  state.ctrl = interact.attach({
    handle = state.ts,
    roots = fixture.roots,
    opts = render_opts,
    width = width,
    max_height = cfg.ui.max_height,
    on_close = close_all,
    extra_help = {
      { "<Tab>/<S-Tab>", "cycle fixture (spike)" },
      { "s", "cycle style (spike)" },
    },
  })

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, function()
      if state then
        fn()
      end
    end, { buffer = state.ts.buf, nowait = true })
  end
  local function switch(delta)
    -- carry the examples toggle across fixture/style rebuilds
    state.show_examples = state.ctrl.opts.show_examples
    state.fixture_idx = (state.fixture_idx + delta - 1) % #state.fixtures + 1
    draw()
  end
  map("<Tab>", function()
    switch(1)
  end)
  map("<S-Tab>", function()
    switch(-1)
  end)
  map("s", function()
    state.show_examples = state.ctrl.opts.show_examples
    state.style_idx = state.style_idx % #styles.names + 1
    draw()
  end)

  local ts_win = state.ts.win
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(ts_win),
    once = true,
    callback = function()
      -- only tear down if this is still the live window (user :q etc.);
      -- during a redraw state.ts has already been detached or replaced
      if state and state.ts and state.ts.win == ts_win then
        state = nil
      end
    end,
  })
end

---@param args string[] optional: initial style name
function M.run(args)
  close_all()
  require("typescope.highlights").apply()

  local want = (args and args[1]) or config.get().ui.style
  local style_idx = 1
  for i, name in ipairs(styles.names) do
    if name == want then
      style_idx = i
    end
  end

  state = {
    fixture_idx = 1,
    style_idx = style_idx,
    show_examples = config.get().show_examples,
    docstring_expanded = false,
    fixtures = fixtures(),
  }
  draw()
end

return M
