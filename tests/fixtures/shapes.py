"""Capability sheet: every class shape TypeScope claims to read, and the ones it doesn't.

Two ways to use this file.

MANUALLY — open it and hover each class. It is a QA sheet for the feature set:
what expands, what shows fields, what shows nothing.

AUTOMATICALLY — tests/test_shapes.lua reads the marker comments below and asserts
extract.type_at agrees with each one. The markers are the expectation, so they
cannot drift from the file the way a table in a test file would.

Marker grammar: a comment line beginning "typescope:" directly above a construct
(above any decorator), carrying "category=" and "fields=", where fields is a
comma-separated list or the word NONE. An optional "note=" explains a NONE. Every
marker in this docstring is described rather than written out, so that the parser
sees exactly the real ones and no examples. A marker that says NONE is documenting a real
gap, not blessing it — when a gap is closed, this file fails until its marker is
updated, which is the point.

Nothing here is executed. It is parsed, by treesitter, exactly as a user's buffer is.
"""

from dataclasses import dataclass
from typing import NamedTuple, NotRequired, Protocol, Required, TypedDict

import pydantic
from pydantic import BaseModel


# === Supported: the declarative shapes ===============================

# typescope: category=dataclass fields=host,port,debug
@dataclass
class ServerConfig:
    host: str
    port: int = 8000
    debug: bool = False


# typescope: category=pydantic fields=name,email
class User(BaseModel):
    name: str
    email: str


# typescope: category=pydantic fields=retries,backoff
@pydantic.dataclasses.dataclass
class RetryPolicy:
    retries: int = 3
    backoff: float = 2.0


# typescope: category=typeddict fields=id,label
class Record(TypedDict):
    id: int
    label: str


# typescope: category=namedtuple fields=x,y
class Point(NamedTuple):
    x: float
    y: float


# typescope: category=protocol fields=NONE methods=read,write note=Protocols carry methods, not fields
class Backend(Protocol):
    def read(self, key: str) -> bytes: ...

    def write(self, key: str, value: bytes) -> None: ...


# A plain class IS read, as long as its attributes are annotated at class level.
# This is the shape people assume is unsupported and the one that actually works.
# typescope: category=class fields=strong,ant
class ClassLevel:
    strong: str = "bar string"
    ant: int = 42


# === Supported: inheritance =========================================

# typescope: category=class fields=env
class BaseConfig:
    env: str = "dev"


# Own fields first, then inherited ones, each tagged with the class it came from.
# typescope: category=class fields=extra bases=BaseConfig
class DerivedConfig(BaseConfig):
    extra: int = 1


# TypedDict total=False badges every field NotRequired; explicit wrappers win.
# typescope: category=typeddict fields=maybe,definitely
class Partial(TypedDict, total=False):
    maybe: str
    definitely: Required[int]


# typescope: category=typeddict fields=needed,optional
class Mixed(TypedDict):
    needed: str
    optional: NotRequired[int]


# === NOT supported: the gaps, deliberately recorded =================

# The shape typescope.nvim-xex is about. Attributes assigned in __init__ are
# invisible twice over: the scan reads the class body's direct children only, so
# it never enters __init__, and `self.strong` parses as an attribute rather than
# an identifier, which the scan also skips. A plain hand-written class is the most
# common Python class there is, so this is the biggest gap in the sheet.
# typescope: category=class fields=NONE note=init-assigned attributes (xex)
class InitAssigned:
    def __init__(self, inflow: dict) -> None:
        self.strong: str = "bar string"
        self.ant: int = 42


# Unannotated class-level assignments are skipped on purpose: without an
# annotation there is no type to show, and guessing from the literal would be a
# different feature (and often wrong).
# typescope: category=class fields=NONE note=no annotation, so no type to report
class Unannotated:
    strong = "bar string"
    ant = 42


# Dunders never appear, annotated or not.
# typescope: category=class fields=visible note=__dunder__ fields are filtered
class Dunders:
    __version__: str = "1.0"
    visible: int = 1


# === Hover targets: LSP-backed, NOT machine-checked here =============
#
# Everything above is pure treesitter and is asserted by test_shapes.lua.
# The calls below need a language server, so they are a MANUAL sheet: open this
# file with basedpyright attached and hover each one. e2e_phase3.lua covers the
# same pipeline against a mock server, not against these lines.


def takes_config(config: ServerConfig, timeout: float = 30.0) -> User:
    """Hover the name: params expand into ServerConfig's fields, return into User's."""
    raise NotImplementedError


def takes_plain(thing: InitAssigned) -> None:
    """Hover the name: `thing` shows as InitAssigned and does NOT expand. That is xex."""
    raise NotImplementedError


def nested(job: DerivedConfig, point: Point, rec: Record) -> Backend:
    """Hover the name: inheritance, NamedTuple, TypedDict and a Protocol return."""
    raise NotImplementedError
