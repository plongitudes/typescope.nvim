-- Linting contract. Run `luacheck lua/ tests/` before opening a PR; CI runs
-- the same. Complements stylua.toml, which handles formatting only.
std = "lua51"
globals = { "vim" }

-- Neovim's Lua is LuaJIT (5.1) plus a few 5.2/5.3 borrowings that ship in it.
read_globals = { "jit", "unpack", "table", "string", "math", "os", "io" }

-- Line length is stylua's job; it wraps at 120 and leaves long string
-- literals and ---@field annotations alone on purpose.
max_line_length = false

exclude_files = { "scratch/" }

files["tests/"] = {
  -- suites define check()/eq_lines() at file scope and share them downward
  allow_defined_top = true,
  -- The suites are long files of numbered, independent sections, and each one
  -- reusing `local r` or `local wide` for its own fixture is the point: the
  -- names stay short and a section reads on its own. Shadowing warnings
  -- (411/421/431) fight that convention for no benefit here. lua/ stays
  -- strict, and is clean.
  ignore = { "411", "421", "431" },
}
