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
  { tokens = { "uuid", "id" }, value = '"a1b2c3d4"' },
  { tokens = { "name" }, value = '"example"' },
}

-- generic per-type examples when no name rule matches
local by_type = {
  bool = "True",
  int = "42",
  float = "3.14",
  str = '"example"',
  bytes = 'b"data"',
}

---@param display? string normalized annotation, e.g. "int | None"
---@return string? base type token, e.g. "int"
local function base_type(display)
  return display and display:match("^([%w_]+)") or nil
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

  local bt = base_type(display)
  if bt and by_type[bt] then
    return by_type[bt]
  end
  -- Optional of something we can't exemplify: None is always valid
  if display and display:find("| None", 1, true) then
    return "None"
  end
  return nil
end

return M
