from dataclasses import dataclass
from typing import Optional, TypedDict

from server_types import Response


@dataclass
class RetryPolicy:
    max_attempts: int = 3
    backoff: float = 2.0


@dataclass
class BaseConfig:
    env: str = "dev"
    verbose: bool = False


@dataclass
class ServerConfig(BaseConfig):
    """Connection settings container."""

    host: str
    port: int
    debug: bool = False
    retry: RetryPolicy = None
    timeout_ms: int | None = None
    verbose: bool = True  # overrides BaseConfig.verbose


class UserRecord(TypedDict, total=False):
    email: str
    name: str
    age: int


def create_server(config: ServerConfig, timeout: float = 30.0) -> Response:
    """Spin up the demo service.

    Prose continues at considerable length in the second paragraph.

    Parameters
    ----------
    config : ServerConfig
        Connection settings for the demo service.
    timeout : float
        Seconds to wait before giving up on startup.
    """
    ...


def update_user(record: UserRecord) -> None:
    ...


LoopMode = Literal["auto", "manual"]
Payload = UserRecord


def send(data: Payload) -> None:
    ...


def configure(mode: LoopMode, count=3) -> None:
    ...


@overload
def fetch(key: int) -> str: ...


@overload
def fetch(key: str, default: str = "auto", policy: RetryPolicy = None, mode: LoopMode = "manual") -> str: ...


def fetch(key, default=None):
    ...


handle = create_server(None, 1.0)
fetched = fetch(1)
fetch2 = fetch("x")
result = update_user(None)
secret = ask("token: ")
attached = attach("app.log")
configured = configure("auto", 1)
sent = send(None)
