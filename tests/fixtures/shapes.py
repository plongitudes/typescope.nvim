"""Capability sheet: every class shape TypeScope claims to read, and the ones it doesn't.

Two ways to use this file.

MANUALLY — open it and hover each class. It is a QA sheet for the feature set:
what expands, what shows fields, what shows nothing.

AUTOMATICALLY — oracle/src/tests.rs reads the marker comments below and asserts
the oracle's answer agrees with each one. The markers are the expectation, so
they cannot drift from the file the way a table in a test file would.

Two marker kinds, both comment lines directly above a construct (above any
decorator), and both described here rather than written out so the parser sees
only the real ones.

The class marker begins "typescope:" and carries "category=" and "fields=",
where fields is a comma-separated list or the word NONE. Protocols may add
"methods=", and an optional "note=" explains a NONE.

The parameter marker begins "typescope-params:" and carries "params=", the
parameters a caller actually supplies — so a method's receiver is absent from it
whatever that receiver is named. A marker that says NONE is documenting a real
gap, not blessing it — when a gap is closed, this file fails until its marker is
updated, which is the point.

Nothing here is executed. It is parsed, by treesitter, exactly as a user's buffer is.
"""

from dataclasses import dataclass
from typing import NamedTuple, NotRequired, Protocol, Required, TypedDict

import pydantic
from pydantic import BaseModel, Field

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


# Field(...) is the required-field sentinel, not a default; default= and
# default_factory= are the value; constraint keywords are not shape.
# typescope: category=pydantic fields=name,tags,limit
class Account(BaseModel):
    name: str = Field(..., min_length=1)
    tags: list[str] = Field(default_factory=list)
    limit: int = Field(default=10, gt=0)


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
# typescope: category=class fields=extra,env note=inherited members inline, tagged with their origin
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


# === Supported: the imperative shape (typescope.nvim-xex) ===========


# Attributes annotated on self in __init__. This is how a large share of ordinary
# hand-written Python looks, and it was the biggest gap in this sheet until xex.
# typescope: category=class fields=strong,ant
class InitAssigned:
    def __init__(self, inflow: dict) -> None:
        self.strong: str = "bar string"
        self.ant: int = 42


# __post_init__ too, which is where a dataclass does its derived fields.
# typescope: category=dataclass fields=raw,derived
@dataclass
class Derived:
    raw: str

    def __post_init__(self) -> None:
        self.derived: int = len(self.raw)


# The receiver name is read from the first parameter, not assumed to be "self" —
# a convention, not a rule.
# typescope: category=class fields=renamed
class OddReceiver:
    def __init__(this) -> None:
        this.renamed: bool = True


# A class-level declaration wins over an __init__ assignment of the same name:
# the declaration is the stated shape, the assignment merely fills it in. `host`
# must appear ONCE, and with the declared annotation.
# typescope: category=class fields=host,port
class DeclaredAndAssigned:
    host: str = "localhost"

    def __init__(self) -> None:
        self.host: str = "overridden"
        self.port: int = 8000


# Only literals become an initial value. `self.inflow: dict = inflow` would
# otherwise render "inflow  dict = inflow", which is noise.
# typescope: category=class fields=literal,from_param
class Initialisers:
    def __init__(self, given: int) -> None:
        self.literal: int = 42
        self.from_param: int = given


# === Formerly unsupported: gaps the oracle closed (design/oracle.md §4) ===


# Unannotated self-assignment: no annotation to read, but the checker infers.
# typescope: category=class fields=strong note=no annotation on self.x; the checker infers str, drawn ≈
class UnannotatedSelf:
    def __init__(self) -> None:
        self.strong = "bar string"


# An attribute set inside a conditional may not exist at runtime; the checker
# binds it as a field regardless, and so does the float.
# typescope: category=class fields=always,sometimes note=a conditional self-assignment is still a field the checker binds
class Conditional:
    def __init__(self, flag: bool) -> None:
        self.always: int = 1
        if flag:
            self.sometimes: int = 2


# Dunders are filtered on self too, not just at class level.
# typescope: category=class fields=shown note=self.__private is filtered like any dunder
class SelfDunder:
    def __init__(self) -> None:
        self.__private: int = 1
        self.shown: int = 2


# Unannotated class-level assignments: no annotation, but the checker infers
# from the literal and the float draws that ≈.
# typescope: category=class fields=strong,ant note=no annotation; the checker infers from the literals, drawn ≈
class Unannotated:
    strong = "bar string"
    ant = 42


# Dunders never appear, annotated or not.
# typescope: category=class fields=visible note=__dunder__ fields are filtered
class Dunders:
    __version__: str = "1.0"
    visible: int = 1


# === Parameters: what a caller actually supplies =====================
#
# The receiver is identified by POSITION, not by name. It used to be dropped by
# matching "self"/"cls", so a method whose receiver was called anything else was
# presented as a parameter the caller passes — and pyright types that Self@Class,
# a diagnostic notation rather than a Python type, which left the example
# generator nothing to work from (typescope.nvim-o6s).


class Receivers:
    # typescope-params: params=x
    def conventional(self, x: int) -> None: ...

    # typescope-params: params=NONE
    def oddly_named(numpy_test) -> None: ...

    # typescope-params: params=y
    def classmethod_like(klass, y: str) -> None: ...

    # A staticmethod's first parameter is NOT a receiver — the caller supplies it.
    # typescope-params: params=a,b
    @staticmethod
    def static(a: int, b: int) -> None: ...

    # typescope-params: params=z
    @classmethod
    def klass(cls, z: int) -> None: ...

    # typescope-params: params=NONE
    @property
    def prop(this) -> int: ...


# A plain function binds no receiver, so its first parameter stays — even when it
# is named like one.
# typescope-params: params=numpy_test,other
def free_function(numpy_test, other: int) -> None: ...


# === Hover targets ===================================================
#
# Everything above is asserted by oracle/src/tests.rs through the markers.
# The functions below are asserted there too (headers, docstrings), and are
# a MANUAL sheet as well: open this file with the oracle attached and hover.


def takes_config(config: ServerConfig, timeout: float = 30.0) -> User:
    """Hover the name: params expand into ServerConfig's fields, return into User's."""
    raise NotImplementedError


def takes_plain(thing: InitAssigned) -> None:
    """Hover the name: `thing` shows as InitAssigned and does NOT expand. That is xex."""
    raise NotImplementedError


def nested(job: DerivedConfig, point: Point, rec: Record) -> Backend:
    """Hover the name: inheritance, NamedTuple, TypedDict and a Protocol return."""
    raise NotImplementedError
