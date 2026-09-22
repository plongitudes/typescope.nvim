from typing import Any, Callable, TypeVar

_T = TypeVar("_T")

def dataclass(cls: type[_T] | None = None, /, **kwargs: Any) -> Any: ...
