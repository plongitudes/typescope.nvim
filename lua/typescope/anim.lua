-- TUI motion: the Braille spinner shown in the float title while Ollama
-- generates. A latency indicator, not eye-candy — so it still appears with
-- ui.animations = false, just as a static "generating…" title.

local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- one spinner per window: a second start on the same win must not capture
-- the first spinner's text as the "original title" and restore it forever
local active = {} ---@type table<integer, { stop: fun(), set_label: fun(l: string) }>

--- Start a title spinner on a float. Returns a handle with stop() (restores
--- the pre-spinner title; safe after the window died) and set_label() for
--- progress text. Starting again on the same window stops the old spinner
--- first.
---@param win integer
---@param label string e.g. "generating"
---@return { stop: fun(), set_label: fun(label: string) }
function M.title_spinner(win, label)
  if active[win] then
    active[win].stop()
  end
  local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
  local original = ok and cfg.title or nil
  local animate = require("typescope.config").get().ui.animations

  local function set_title(text)
    pcall(vim.api.nvim_win_set_config, win, { title = { { text, "TypeScopeTitle" } } })
  end

  local timer
  if animate then
    timer = vim.uv.new_timer()
    local i = 0
    timer:start(
      0,
      100,
      vim.schedule_wrap(function()
        if not vim.api.nvim_win_is_valid(win) then
          return
        end
        i = i % #FRAMES + 1
        set_title((" %s %s… "):format(FRAMES[i], label))
      end)
    )
  else
    set_title((" %s… "):format(label))
  end

  local handle
  handle = {
    set_label = function(new_label)
      label = new_label
      if not animate then
        set_title((" %s… "):format(label))
      end
    end,
    stop = function()
      if timer then
        timer:stop()
        timer:close()
        timer = nil
      end
      if active[win] == handle then
        active[win] = nil
      end
      if original and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_set_config, win, { title = original })
      end
    end,
  }
  active[win] = handle
  return handle
end

-- NOTE: the pending-example animation used to live here as a per-frame
-- nvim_set_hl into a window-local highlight namespace, plus an nvim__redraw to
-- force the paint (namespace highlight changes schedule no redraw of their
-- own). Tony's travelling-wave design retired all of it: brightness tracks
-- block height, so the groups are static and only the TEXT moves — and text
-- repaints itself. What's left is a frame clock in interact.lua and pure
-- geometry in render.lua (jit).

return M
