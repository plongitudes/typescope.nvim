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
    ...


def update_user(record: UserRecord) -> None:
    ...


LoopMode = Literal["auto", "manual"]
Payload = UserRecord


def send(data: Payload) -> None:
    ...


def configure(mode: LoopMode, count=3) -> None:
    ...


handle = create_server(None, 1.0)
result = update_user(None)
secret = ask("token: ")
configured = configure("auto", 1)
sent = send(None)
