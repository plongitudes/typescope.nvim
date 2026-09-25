from dataclasses import dataclass, field
from enum import Enum
from typing import overload


class LogLevel(Enum):
    DEBUG = "debug"
    INFO = "info"
    WARNING = "warning"


@dataclass
class Retry:
    """How a failed request is retried before the caller sees the error."""

    attempts: int = 3
    backoff: float = 0.5


@dataclass
class ServerConfig:
    """Where the service listens, and how it behaves once it is up.

    Retries apply to outbound calls only: an inbound request that fails
    is answered with a 503 and never retried.
    """

    host: str
    port: int = 8080
    debug: bool = False
    retry: Retry = field(default_factory=Retry)


@dataclass
class User:
    name: str
    email: str
    admin: bool = False


def serve(host: str, port: int = 8080, workers: int = 4, level: LogLevel = LogLevel.INFO) -> None:
    """Start the service and block until it is stopped."""


@overload
def lookup(user_id: int) -> User: ...
@overload
def lookup(email: str, *, active: bool = True) -> User: ...
def lookup(key: int | str, *, active: bool = True) -> User:
    """Find one user by numeric id or by email address."""
    raise NotImplementedError


def start(config: ServerConfig, owner: User) -> None:
    """Bring the service up with an owner on record."""


serve()
lookup()
start(ServerConfig("0.0.0.0"), User("ada", "ada@example.com"))
