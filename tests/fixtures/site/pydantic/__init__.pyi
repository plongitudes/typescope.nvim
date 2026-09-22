# Stub of the pydantic surface the fixtures use. pyrefly keys its BaseModel
# support off this qualified name, so the stub stands in for the real package.
from typing import Any

class BaseModel:
    model_fields: dict[str, Any]
    def __init__(self, **data: Any) -> None: ...
    def model_dump(self) -> dict[str, Any]: ...

def Field(default: Any = ..., *, default_factory: Any = ..., **kwargs: Any) -> Any: ...
