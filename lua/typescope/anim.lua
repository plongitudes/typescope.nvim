-- TUI motion: the Braille spinner shown in the float title while Ollama
-- generates. A latency indicator, not eye-candy — so it still appears with
-- ui.animations = false, just as a static "generating…" title.

local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- Start a title spinner on a float. Returns a handle whose stop() restores
--- the original title (safe to call after the window died).
---@param win integer
---@param label string e.g. "generating"
---@return { stop: fun() }
function M.title_spinner(win, label)
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

  return {
    stop = function()
      if timer then
        timer:stop()
        timer:close()
        timer = nil
      end
      if original and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_set_config, win, { title = original })
      end
    end,
  }
end

return M
