-- Client-side overload matching (h8h). basedpyright reports activeSignature=0
-- even when the args only fit a later overload, so a 0 is indistinguishable
-- from "no idea". When the server's answer is ambiguous (0 or absent), the
-- surfaces match the call's written arguments against each overload group's
-- parameter shape — arity, keyword names, literal kinds — and take the first
-- best fit, mirroring pyright's first-match-wins overload semantics. A
-- nonzero server answer is a real signal and is never overridden.
--
-- Language-neutral: works on resolved U4 group nodes and the extractor's
-- call_args classification, never on source text.

local M = {}

-- literal kind (extractor vocabulary) → the annotation word naming it exactly
local KIND_WORD = { string = "str", integer = "int", float = "float", bool = "bool", none = "None" }

-- An annotation built ONLY of these words is exhaustive: a literal of a
-- different kind is a hard mismatch (`key: int` can never take "x"). Any
-- other word (a class, a protocol, an alias) may admit the literal in ways a
-- text match can't see — loguru's `sink: TextIO | Writable | Handler` takes
-- no string, but `mode: LoopMode` (an unexpanded alias) might — so those
-- annotations stay neutral instead of disqualifying.
local SCALAR = { str = true, int = true, float = true, bool = true, bytes = true, complex = true, None = true }

local function has_word(display, word)
  return display:find("%f[%w_]" .. word .. "%f[^%w_]") ~= nil
end

--- One argument's literal kind against one annotation display string.
---@param display string normalized annotation text
---@param kind string extractor literal kind ("other" = unjudgeable)
---@return "match"|"mismatch"|"unknown"
local function verdict(display, kind)
  local word = KIND_WORD[kind]
  if not word then
    return "unknown"
  end
  if has_word(display, word) or (kind == "integer" and has_word(display, "float")) then
    return "match" -- int literals satisfy float params
  end
  if has_word(display, "Any") or has_word(display, "object") then
    return "unknown"
  end
  if kind == "string" and has_word(display, "Literal") then
    return "match" -- Literal members are (quote-stripped) strings after normalize
  end
  for w in display:gmatch("[%a_][%w_]*") do
    if not SCALAR[w] then
      return "unknown"
    end
  end
  return "mismatch"
end

--- One group's callability facts from its param children.
local function shape_of(group)
  local s = { positional = {}, names = {}, varargs = false, kwargs = false }
  for _, c in ipairs(group.children) do
    if c.kind == "param" then
      if c.name:match("^%*%*") then
        s.kwargs = true
      elseif c.name:match("^%*") then
        s.varargs = true
      else
        s.names[c.name] = c
        if c.pass_mode ~= "*" then
          table.insert(s.positional, c)
        end
      end
    end
  end
  return s
end

--- Score a group against the written args; nil = not viable. Required-param
--- coverage is deliberately NOT checked: the call is usually mid-typing.
local function score(group, args)
  local s = shape_of(group)
  if #args.positional > #s.positional and not s.varargs then
    return nil
  end
  local total = 0
  local function judge(param, kind)
    local v = verdict(param.type.display, kind)
    if v == "match" then
      total = total + 1
    end
    return v ~= "mismatch"
  end
  for i, a in ipairs(args.positional) do
    local p = s.positional[i]
    if p and not judge(p, a.kind) then
      return nil
    end
  end
  for _, kw in ipairs(args.keywords) do
    local p = s.names[kw.name]
    if p then
      if not judge(p, kw.kind) then
        return nil
      end
    elseif not s.kwargs then
      return nil
    end
  end
  return total
end

--- First overload with the best score. nil when the args are unjudgeable or
--- no group is viable — the caller keeps the server's/current choice.
---@param groups typescope.Node[] overload group roots (resolve U4 output)
---@param args? { positional: table[], keywords: table[] } extractor call_args
---@return integer?
function M.pick(groups, args)
  if not args then
    return nil
  end
  local best, best_score
  for i, g in ipairs(groups) do
    local sc = score(g, args)
    if sc and (not best_score or sc > best_score) then
      best, best_score = i, sc
    end
  end
  return best
end

return M
