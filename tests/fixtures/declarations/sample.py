from pathlib import Path

from models import Bar, Empty

LOG: Path = Path("log")


class Holder:
    handle: Path

    def __init__(self) -> None:
        self.bar: Bar = Bar()
        self.blocked: Path = Path("blocked")
        self.strong: str = "s"
        self.mapping: dict[str, Bar] = {}
        self.empty: Empty = Empty()
