"""Spike 1 fixture: the four questions the syntax-reading resolver cannot answer.

Each target below is something TypeScope draws wrong or not at all today; the
probe evaluates the type at each and prints STRUCTURE (members, params, type
args) rather than pyright's hover prose.
"""

from dataclasses import dataclass
from enum import Enum
from typing import Generic, TypeVar

T = TypeVar("T")


class Color(Enum):
    RED = 1
    GREEN = 2


@dataclass
class ServerConfig:
    host: str
    port: int = 8000


class Box(Generic[T]):
    item: T
    count: int = 0


class Response:
    status: int

    def __init__(self, body: bytes) -> None:
        self.body: bytes = body
        self.parsed = {"k": 1}

    @property
    def ok(self) -> bool:
        return self.status < 400


class Derived(ServerConfig):
    debug: bool = False


def fetch(url: str) -> Response: ...


def fetch_maybe(url: str) -> Response | None: ...


def use(b: Box[ServerConfig], c: Color, d: Derived) -> Response:
    resp = fetch("x")
    if resp.ok:
        return resp
    return fetch("y")


def first(xs: list[T]) -> T: ...


n = first([1, 2, 3])
maybe = fetch_maybe("z")
if maybe is not None:
    narrowed = maybe
