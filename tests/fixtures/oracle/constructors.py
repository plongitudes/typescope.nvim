"""Calls to classes whose constructors come from different places (typescope.nvim-pmy)."""

from argparse import ArgumentParser
from dataclasses import InitVar, dataclass, field
from smtplib import SMTP
from enum import Enum
from typing import NamedTuple, dataclass_transform

from pydantic import BaseModel


class Plain:
    x: int = 0


class MyParser(ArgumentParser):
    pass


class MyDict(dict):
    pass


@dataclass
class Base:
    x: int = 1


@dataclass
class Child(Base):
    y: str = "y"
    hidden: int = field(default=0, init=False)
    seed: InitVar[int] = 0


class Point(NamedTuple):
    x: int
    y: int = 0


class Model(BaseModel):
    n: int = 3


@dataclass_transform()
class ModelBase:
    """Like SQLAlchemy's DeclarativeBase: a written __init__ on the base, and
    subclasses get a synthesized one from their fields."""

    def __init__(self, **kw: object) -> None: ...


class Record(ModelBase):
    title: str = "untitled"


class Color(Enum):
    RED = 1


mailer = SMTP("localhost")
parser = MyParser()
plain = Plain()
child = Child()
mapping = MyDict()
point = Point(1)
model = Model()
record = Record()
color = Color(1)
