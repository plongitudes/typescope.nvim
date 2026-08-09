# Plays loguru/__init__.pyi: the handwritten stub holding the @overload set
# that declaration resolves to. (.py rather than .pyi only so the mock
# server's glob picks it up; the parse path is identical.)
from typing import TextIO, overload


@overload
def attach(sink: TextIO, *, level: int = 0, colorize: bool = False) -> int: ...
@overload
def attach(sink: str, *, level: int = 0, colorize: bool = False) -> int: ...
