-- :TypeScope spike [style] — visual prototyping harness (phase 1).
-- Opens a mock signature float + the TypeScope float with fixture trees, no
-- LSP involved. Everything rendered here goes through the production
-- render.lua/float.lua path, so style decisions made in the spike ship as-is.

local model = require("typescope.model")
local render = require("typescope.render")
local styles = require("typescope.styles")
local float = require("typescope.float")
local config = require("typescope.config")

local M = {}

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
---@field sig typescope.FloatHandle?
---@field ts typescope.FloatHandle?
---@field fixtures table[]
local state = nil

local function close_all()
  if not state then
    return
  end
  float.close(state.sig)
  float.close(state.ts)
  state = nil
end

local function draw()
  local fixture = state.fixtures[state.fixture_idx]
  local style_name = styles.names[state.style_idx]
  local cfg = config.get()

  local result = render.render(fixture.roots, {
    style = styles.get(style_name),
    max_width = cfg.ui.max_width,
    show_examples = state.show_examples,
    example_kind = "heuristic",
  })

  local sig_line = fixture.signature
  local width = math.min(cfg.ui.max_width, math.max(result.width, #sig_line, 40))
  local height = math.min(cfg.ui.max_height, #result.lines)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local sig_row = 2

  -- Dev harness: rebuild both floats each redraw; flicker-free transitions are
  -- phase 2. Detach handles BEFORE closing — nvim_win_close fires WinClosed
  -- synchronously, and the teardown autocmd must see this as a redraw, not a
  -- user close.
  local old_sig, old_ts = state.sig, state.ts
  state.sig, state.ts = nil, nil
  float.close(old_sig)
  float.close(old_ts)

  local paren = sig_line:find("%(") or #sig_line
  state.sig = float.open({
    lines = { sig_line },
    highlights = { { line = 0, col_start = 0, col_end = paren - 1, group = "@function" } },
    title = " signature (mock) ",
    relative = "editor",
    row = sig_row,
    col = col,
    width = width,
    height = 1,
    border = cfg.ui.border,
    focusable = false,
  })

  state.ts = float.open({
    lines = result.lines,
    highlights = result.highlights,
    title = (" typescope · %s · %s "):format(fixture.name, style_name),
    footer = " <Tab> fixture · s style · e examples · b bg · q close ",
    relative = "editor",
    row = sig_row + 3, -- sig height 1 + its two border rows
    col = col,
    width = width,
    height = height,
    border = cfg.ui.border,
    enter = true,
  })

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, function()
      if state then
        fn()
      end
    end, { buffer = state.ts.buf, nowait = true })
  end
  map("<Tab>", function()
    state.fixture_idx = state.fixture_idx % #state.fixtures + 1
    draw()
  end)
  map("<S-Tab>", function()
    state.fixture_idx = (state.fixture_idx - 2) % #state.fixtures + 1
    draw()
  end)
  map("s", function()
    state.style_idx = state.style_idx % #styles.names + 1
    draw()
  end)
  map("e", function()
    state.show_examples = not state.show_examples
    draw()
  end)
  map("b", function()
    vim.o.background = vim.o.background == "dark" and "light" or "dark"
  end)
  map("q", close_all)
  map("<Esc>", close_all)

  local ts_win = state.ts.win
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(ts_win),
    once = true,
    callback = function()
      -- only tear down if this is still the live window (user :q etc.);
      -- during a redraw state.ts has already been detached or replaced
      if state and state.ts and state.ts.win == ts_win then
        local sig = state.sig
        state = nil
        float.close(sig)
      end
    end,
  })
end

---@param args string[] optional: initial style name
function M.run(args)
  close_all()
  require("typescope.highlights").apply()

  local style_idx = 1
  for i, name in ipairs(styles.names) do
    if name == (args and args[1]) then
      style_idx = i
    end
  end

  state = {
    fixture_idx = 1,
    style_idx = style_idx,
    show_examples = config.get().show_examples,
    fixtures = fixtures(),
  }
  draw()
end

return M
