-- Extraction coverage: every supported Python construct through
-- extract/python.lua on inline source strings (vim.treesitter string parser —
-- no LSP involved). Run headless:
--   nvim --headless --clean \
--     --cmd "set rtp+=. rtp+=~/.local/share/nvim/site" \
--     -c "luafile tests/test_extract.lua" -c "qa!"

local py = require("typescope.extract.python")

local failures = 0
local function check(desc, cond, detail)
  print((cond and "PASS " or "FAIL ") .. desc .. (not cond and detail and (" — " .. detail) or ""))
  if not cond then
    failures = failures + 1
  end
end

local function find_pos(src, pat)
  for i, line in ipairs(vim.split(src, "\n")) do
    local col = line:find(pat)
    if col then
      return i - 1, col - 1 + math.floor(#pat / 4)
    end
  end
  error("pattern not found: " .. pat)
end

---------------------------------------------------------------- function_info
local fn_src = [[
def create(config: ServerConfig, timeout: float = 30.0, flag=True, bare, *args, **kw) -> Response:
    ...

class Svc:
    def method(self, x: int) -> None: ...
    @classmethod
    def make(cls, name: str) -> "Svc": ...
]]

local info = py.function_info(fn_src, 0, 4)
check("fn name", info.name == "create")
check("param count (self/cls never apply here)", #info.params == 6)
local p = {}
for _, entry in ipairs(info.params) do
  p[entry.name] = entry
end
check("typed param has type node", p.config and p.config.type_node ~= nil)
check("typed default param", p.timeout and p.timeout.type_node ~= nil and p.timeout.default == "30.0")
check("untyped default param", p.flag and p.flag.type_node == nil and p.flag.default == "True")
check("bare param", p.bare and p.bare.type_node == nil and p.bare.default == nil)
check("splat params kept with stars", p["*args"] ~= nil and p["**kw"] ~= nil)
check("return type node present", info.return_type ~= nil)

local mrow = find_pos(fn_src, "def method")
local minfo = py.function_info(fn_src, mrow, 8)
check("self skipped in methods", #minfo.params == 1 and minfo.params[1].name == "x")
local crow = find_pos(fn_src, "def make")
local cinfo = py.function_info(fn_src, crow, 8)
check("cls skipped in classmethods", #cinfo.params == 1 and cinfo.params[1].name == "name")
check("not-a-function returns nil", py.function_info("x = 1\n", 0, 0) == nil)

---------------------------------------------------------------- annotation
local ann_src = "def f(a: dict[str, pkg.Config], b: Optional[Retry], c: Literal['x, y'], d: dict[Cfg, Cfg]) -> None: ..."
local ainfo = py.function_info(ann_src, 0, 4)
local ap = {}
for _, entry in ipairs(ainfo.params) do
  ap[entry.name] = py.annotation(ann_src, entry.type_node)
end
check("builtins filtered from refs", #ap.a.refs == 1 and ap.a.refs[1].name == "pkg.Config")
check("dotted ref position on final identifier", ap.a.refs[1].col == ann_src:find("Config") - 1)
check("Optional wrapper filtered, inner kept", #ap.b.refs == 1 and ap.b.refs[1].name == "Retry")
check("strings never chased (Literal commas safe)", #ap.c.refs == 0)
check("duplicate refs deduped", #ap.d.refs == 1)

---------------------------------------------------------------- normalization
local norm_src = "def g(a: typing.Optional[str], b: typing.Union['X', typing.Callable, str], c: typing.Dict[str, typing.List[int]], d: Optional[Union[int, str]], e: int | None) -> None: ..."
local ninfo = py.function_info(norm_src, 0, 4)
local want_norm = {
  a = "str | None",
  b = "X | Callable | str",
  c = "dict[str, list[int]]",
  d = "int | str | None",
  e = "int | None",
}
for _, entry in ipairs(ninfo.params) do
  local got = py.annotation(norm_src, entry.type_node).display
  check("normalize " .. entry.name .. " -> " .. want_norm[entry.name], got == want_norm[entry.name], got)
end

---------------------------------------------------------------- constructs
local cls_src = [[
import typing
from dataclasses import dataclass, field
from pydantic import BaseModel, Field

@dataclass
class Plain:
    host: str
    tags: list[str] = field(default_factory=list)
    __private: int = 0

@pydantic.dataclasses.dataclass
class PydDC:
    x: int = 0

class Model(BaseModel):
    port: int = Field(8080, ge=1)
    retry: Retry = Field(default=None)
    items: list[str] = Field(default_factory=list)
    required: str = Field(...)

class Record(typing.TypedDict, total=False):
    email: Required[str]
    name: str
    age: NotRequired[int]

class Strict(TypedDict):
    key: str

class Point(NamedTuple):
    x: int
    y: int = 0

class Store(Protocol):
    root: str
    def read(self, path: str) -> bytes: ...
    def __repr__(self) -> str: ...

class Vanilla:
    attr: int
]]

local function type_of(name)
  local row = find_pos(cls_src, "class " .. name)
  return py.type_at(cls_src, row, 7)
end

local plain = type_of("Plain")
check("dataclass category", plain.category == "dataclass")
check("dataclass field count (dunder skipped)", #plain.fields == 2)
check("dataclass field(default_factory) unwrapped", plain.fields[2].default == "list")

check("pydantic dataclass decorator", type_of("PydDC").category == "pydantic")

local m = type_of("Model")
check("BaseModel category", m.category == "pydantic")
local mf = {}
for _, f in ipairs(m.fields) do
  mf[f.name] = f
end
check("Field positional default", mf.port.default == "8080")
check("Field(default=) unwrapped", mf.retry.default == "None")
check("Field(default_factory=) unwrapped", mf.items.default == "list")
check("Field(...) means required (no default)", mf.required.default == nil)

local rec = type_of("Record")
check("TypedDict category", rec.category == "typeddict")
local rf = {}
for _, f in ipairs(rec.fields) do
  rf[f.name] = f
end
check("Required[] badge + unwrap", rf.email.badge == "Required" and py.annotation(cls_src, rf.email.type_node).display == "str")
check("total=False implies NotRequired", rf.name.badge == "NotRequired")
check("NotRequired[] badge + unwrap", rf.age.badge == "NotRequired" and py.annotation(cls_src, rf.age.type_node).display == "int")
check("total=True TypedDict has no badges", type_of("Strict").fields[1].badge == nil)

local pt = type_of("Point")
check("NamedTuple category + fields", pt.category == "namedtuple" and #pt.fields == 2 and pt.fields[2].default == "0")

local store = type_of("Store")
check("Protocol category", store.category == "protocol")
check("Protocol attribute extracted", store.fields[1].name == "root")
check("Protocol method with self stripped", store.methods[1].name == "read" and store.methods[1].signature == "(path: str) -> bytes")
check("Protocol dunder methods skipped", #store.methods == 1)

check("plain class still yields fields", type_of("Vanilla").category == "class" and #type_of("Vanilla").fields == 1)

local _, marker = py.type_at(cls_src, 1, 25) -- on 'dataclass' in the from-import
check("import statement yields marker", marker == "import")

print(failures == 0 and "EXTRACT ALL PASS" or ("EXTRACT " .. failures .. " FAILURES"))
