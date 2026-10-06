"""Calls to classes whose constructors come from different places (typescope.nvim-pmy)."""

from argparse import ArgumentParser
from dataclasses import InitVar, dataclass, field
from smtplib import SMTP
from typing import NamedTuple

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


mailer = SMTP("localhost")
parser = MyParser()
plain = Plain()
child = Child()
mapping = MyDict()
point = Point(1)
model = Model()
