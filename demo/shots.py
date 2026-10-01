from dataclasses import dataclass


@dataclass
class ServerConfig:
    host: str
    port: int = 8080
    debug: bool = False


@dataclass
class Response:
    status: int
    body: bytes


def create_server(config: ServerConfig, timeout: float = 30.0) -> Response:
    """Spin up the demo service."""
    raise NotImplementedError


create_server(ServerConfig("localhost"))
