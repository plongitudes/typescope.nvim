---@class typescope.Charset
---@field vert string continuation bar for ancestor levels
---@field branch string prefix for a non-last child
---@field last string prefix for the last child
---@field expanded string marker on an expanded expandable node
---@field collapsed string marker on a collapsed expandable node
---@field leaf string marker on a non-expandable root (aligns with expanded/collapsed)
---@field unresolved string indicator when TreeSitter parsing failed
---@field inherit string prefix for the origin class of inherited fields
---@field evaluated string prefix for hover-evaluated type decorations

local M = {}

-- All charsets use plain Unicode/ASCII only — no nerd-font glyphs — so every
-- style works in any font. vim.g.typescope_nerd_font may later opt into icons.
---@type table<string, typescope.Charset>
local charsets = {
  unicode = {
    vert = "│ ",
    branch = "├─ ",
    last = "└─ ",
    expanded = "▾ ",
    collapsed = "▸ ",
    leaf = "· ",
    unresolved = "[?]",
    inherit = "↑",
    evaluated = "≈ ",
  },
  ascii = {
    vert = "| ",
    branch = "+- ",
    last = "\\- ",
    expanded = "v ",
    collapsed = "> ",
    leaf = "- ",
    unresolved = "[?]",
    inherit = "^",
    evaluated = "~ ",
  },
  minimal = {
    vert = "  ",
    branch = "  ",
    last = "  ",
    expanded = "- ",
    collapsed = "+ ",
    leaf = "  ",
    unresolved = "[?]",
    inherit = "^",
    evaluated = "~ ",
  },
  rounded = {
    vert = "│ ",
    branch = "├─ ",
    last = "╰─ ",
    expanded = "▾ ",
    collapsed = "▸ ",
    leaf = "· ",
    unresolved = "[?]",
    inherit = "↑",
    evaluated = "≈ ",
  },
}

M.names = { "unicode", "ascii", "minimal", "rounded" }

---@param name string
---@return typescope.Charset
function M.get(name)
  return charsets[name] or charsets.unicode
end

return M
