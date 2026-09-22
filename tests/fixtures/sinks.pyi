# Plays loguru/__init__.pyi: the handwritten stub holding the @overload set.
# A checker prefers this .pyi over sinks.py beside it; the runtime module
# keeps the docstring.
from typing import TextIO, overload


@overload
def attach(sink: TextIO, *, level: int = 0, colorize: bool = False) -> int: ...
@overload
def attach(sink: str, *, level: int = 0, colorize: bool = False) -> int: ...
