-- End-to-end test of the phase-3 LSP pipeline against the in-process mock
-- server. Run headless:
--   nvim --headless --clean \
--     --cmd "set rtp+=. rtp+=~/.local/share/nvim/site" \
--     -c "luafile tests/e2e_phase3.lua" -c "qa!"

local root = vim.fn.getcwd()
local fixture_dir = root .. "/tests/fixtures"

local failures = 0
local function check(desc, cond)
  print((cond and "PASS " or "FAIL ") .. desc)
  if not cond then
    failures = failures + 1
  end
end

local function float_lines()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local c = vim.api.nvim_win_get_config(w)
    if c.relative ~= "" and vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "typescope" then
      return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), w
    end
  end
end

-- open the fixture and attach the mock server
vim.cmd.edit(fixture_dir .. "/sample.py")
local bufnr = vim.api.nvim_get_current_buf()
local client_id = vim.lsp.start({
  name = "typescope-mock",
  cmd = require("tests.mock_server").cmd(fixture_dir),
  root_dir = fixture_dir,
})
vim.wait(1000, function()
  return #vim.lsp.get_clients({ bufnr = bufnr }) > 0
end)
check("mock LSP attached", #vim.lsp.get_clients({ bufnr = bufnr }) > 0)

-- cursor on the create_server *call*
local call_line
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if l:find("handle = create_server") then
    call_line = i
  end
end
vim.api.nvim_win_set_cursor(0, { call_line, 12 })

require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)

local lines = float_lines()
check("float opened", lines ~= nil)
if lines then
  local all = table.concat(lines, "\n")
  check("param config expanded with fields", all:find("host") and all:find("port") and all:find("debug"))
  check("depth-2: retry's RetryPolicy category resolved", all:find("retry") ~= nil)
  check("union annotation intact", all:find("int | None", 1, true) ~= nil)
  check("param timeout with default", all:find("timeout") and all:find("30%.0"))
  check("returns Response present, collapsed", all:find("returns") and not all:find("status"))

  -- expand retry (depth 2 resolved its fields inline)
  local _, w = float_lines()
  vim.api.nvim_set_current_win(w)
  for i, l in ipairs(lines) do
    if l:find("retry") then
      vim.api.nvim_win_set_cursor(w, { i, 0 })
      break
    end
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  local all2 = table.concat(float_lines(), "\n")
  check("retry expands to max_attempts/backoff", all2:find("max_attempts") and all2:find("backoff"))

  -- expand returns: cross-file resolution into server_types.py
  for i, l in ipairs(float_lines()) do
    if l:find("returns") then
      vim.api.nvim_win_set_cursor(w, { i, 0 })
      break
    end
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  vim.wait(500, function()
    return table.concat(float_lines() or {}, "\n"):find("status") ~= nil
  end)
  local all3 = table.concat(float_lines(), "\n")
  check("returns expands to Response fields (cross-file)", all3:find("status") and all3:find("body"))
end

require("typescope").close()
check("closed cleanly", float_lines() == nil)

-- TypedDict path: badges from total=False
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if l:find("result = update_user") then
    vim.api.nvim_win_set_cursor(0, { i, 12 })
  end
end
require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
local lines4 = float_lines()
check("typeddict float opened", lines4 ~= nil)
if lines4 then
  local all4 = table.concat(lines4, "\n")
  check("typeddict fields with NotRequired badges", all4:find("email") and all4:find("NotRequired"))
  check("returns None leaf", all4:find("returns%s+None") ~= nil)
end
require("typescope").close()

-- declaration fallback: `ask` resolves (definition) to a module alias
-- assignment, then (declaration) to the annotated def — the getpass case
for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if l:find("secret = ask") then
    vim.api.nvim_win_set_cursor(0, { i, 10 })
  end
end
require("typescope").open()
vim.wait(2000, function()
  return float_lines() ~= nil
end)
local lines5 = float_lines()
check("alias float opened via declaration fallback", lines5 ~= nil)
if lines5 then
  local all5 = table.concat(lines5, "\n")
  check("stub params rendered", all5:find("prompt") and all5:find("echo"))
  check("stub annotations rendered", all5:find("str") and all5:find("bool"))
  check("stub return type rendered", all5:find("returns") ~= nil)
end
require("typescope").close()

print(failures == 0 and "ALL PASS" or (failures .. " FAILURES"))
