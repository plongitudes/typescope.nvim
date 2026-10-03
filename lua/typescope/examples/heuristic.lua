-- Heuristic example values: name-token patterns first, type fallbacks second.
-- Zero latency, no LSP — pure name/type pattern matching per the requirements
-- table.
--
-- Matching is by exact NAME TOKEN (split on underscores/case boundaries are
-- not needed for v1 — snake_case dominates Python), so "timeout_ms" hits
-- "timeout" but "width" does not hit "id".

local M = {}

---@class typescope.HeuristicRule
---@field tokens string[] name tokens that trigger this rule
---@field value string type-independent example
---@field by_type? table<string, string> overrides keyed by the base type token

-- Matching strategy (Tony's call, 2026-07-29 — revisit if it doesn't hold):
-- HEAD NOUN FIRST. In snake_case compounds the rightmost token is the head —
-- server_name IS a name (of a server), file_url IS a url — so the last token
-- is tried against every rule before any-token matching falls back to the
-- rule order below (earlier = more specific).
local rules = {
  { tokens = { "email" }, value = '"user@example.com"' },
  { tokens = { "url", "endpoint", "uri" }, value = '"https://example.com"' },
  { tokens = { "host", "hostname", "server" }, value = '"localhost"' },
  { tokens = { "port" }, value = "8080", by_type = { str = '"8080"' } },
  { tokens = { "timeout", "ttl", "interval", "delay" }, value = "30", by_type = { float = "30.0" } },
  { tokens = { "path", "dir", "file", "filename" }, value = '"/tmp/example"' },
  { tokens = { "uuid", "id" }, value = '"a1b2c3d4"', by_type = { int = "42" } },
  { tokens = { "name" }, value = '"example"' },
}

-- generic per-type examples when no name rule matches
local by_type = {
  bool = "True",
  int = "2600",
  float = "3.14159",
  str = '"example"',
  bytes = 'b"data"',
}

---@param display? string normalized annotation, e.g. "int | None"
---@return string? base type token, e.g. "int"
local function base_type(display)
  return display and display:match("^([%w_]+)") or nil
end

--- The first member of a leading `Literal[...]`, as written: `Literal[True]`
--- → `True`, `Literal["auto", "h11"] | None` → `"auto"`. A Literal's members
--- are the only values it admits, so one of them IS the example, and no name
--- rule may override it (typescope.nvim-g1c). Quotes are respected, so a comma
--- or bracket inside a string member doesn't end it.
---@param display? string
---@return string?
local function literal_member(display)
  local body = display and display:match("^Literal%[(.*)$")
  if not body then
    return nil
  end
  local quote = nil
  for i = 1, #body do
    local c = body:sub(i, i)
    if quote then
      if c == quote then
        quote = nil
      end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == "," or c == "]" then
      local member = vim.trim(body:sub(1, i - 1))
      return member ~= "" and member or nil
    end
  end
  return nil
end

--- The members of a top-level union, in order: `list[str | int] | None` is
--- two members, not three — a `|` inside brackets, parens or a string belongs
--- to the member around it.
---@param display? string
---@return string[]
local function arms(display)
  local out, depth, quote, start = {}, 0, nil, 1
  display = display or ""
  for i = 1, #display do
    local c = display:sub(i, i)
    if quote then
      if c == quote then
        quote = nil
      end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == "[" or c == "(" then
      depth = depth + 1
    elseif c == "]" or c == ")" then
      depth = depth - 1
    elseif c == "|" and depth == 0 then
      table.insert(out, vim.trim(display:sub(start, i - 1)))
      start = i + 1
    end
  end
  table.insert(out, vim.trim(display:sub(start)))
  return out
end

--- A type example for a union, from its non-None members. Falling back to
--- None for the whole union left the row blank, since None is usually also
--- its default and annotate() drops an example that restates the default
--- (typescope.nvim-g1c, gap 2). But the first member that has an example is
--- not always a fair one: `PathLike[bytes] | bytes | str` for subprocess's cwd
--- would give b"data", and `IO[Any] | int` for stdin would give a bare int.
--- So: `str` when it's a member. Otherwise only when EVERY member has a type
--- example — mixed with a type we can't exemplify, the one we can is often
--- not what people pass — preferring float over int, to show that a float is
--- accepted.
---@param display? string
---@return string?
local function union_value(display)
  local members = {}
  for _, arm in ipairs(arms(display)) do
    if arm ~= "None" then
      members[base_type(arm) or ""] = true
      if not by_type[base_type(arm) or ""] then
        members.unknown = true
      end
    end
  end
  if members.str then
    return by_type.str
  end
  if members.unknown then
    return nil
  end
  if members.float then
    return by_type.float
  end
  for _, arm in ipairs(arms(display)) do
    if by_type[base_type(arm) or ""] then
      return by_type[base_type(arm)]
    end
  end
  return nil
end

---@param token string
---@return typescope.HeuristicRule?
local function rule_for_token(token)
  for _, rule in ipairs(rules) do
    for _, t in ipairs(rule.tokens) do
      if t == token then
        return rule
      end
    end
  end
end

--- Example literal for a field, or nil when nothing sensible applies.
---@param name string field/param name
---@param display? string normalized type annotation
---@return string?
function M.value(name, display)
  if display == "None" then
    return "None"
  end
  local member = literal_member(display)
  if member then
    return member
  end
  local ordered = {}
  for tok in name:lower():gmatch("%w+") do
    table.insert(ordered, tok)
  end

  -- head noun first, then any token in rule order
  local rule = #ordered > 0 and rule_for_token(ordered[#ordered]) or nil
  if not rule then
    for _, r in ipairs(rules) do
      for _, t in ipairs(r.tokens) do
        for _, tok in ipairs(ordered) do
          if t == tok then
            rule = r
            break
          end
        end
        if rule then
          break
        end
      end
      if rule then
        break
      end
    end
  end
  if rule then
    local bt = base_type(display)
    return (rule.by_type and bt and rule.by_type[bt]) or rule.value
  end

  local value = union_value(display)
  if value then
    return value
  end
  -- Optional of something we can't exemplify: None is always valid
  if display and display:find("| None", 1, true) then
    return "None"
  end
  return nil
end

return M
