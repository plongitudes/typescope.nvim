from models import Bar, Empty
from typeshed_io import TextIO

LOG: TextIO = open_log()


class Holder:
    handle: TextIO

    def __init__(self) -> None:
        self.bar: Bar = Bar()
        self.blocked: TextIO = open_log()
        self.strong: str = "s"
        self.mapping: dict[str, Bar] = {}
        self.empty: Empty = Empty()
