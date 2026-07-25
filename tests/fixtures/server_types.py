from dataclasses import dataclass


@dataclass
class Headers:
    content_type: str = "application/json"
    length: int = 0


@dataclass
class Response:
    status: int
    body: bytes
    headers: Headers = None
