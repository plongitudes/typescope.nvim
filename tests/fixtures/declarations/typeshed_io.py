# "typeshed" in the path is what is_typeshed keys on. This class HAS structure,
# so a test that finds no structure drawn has proved the guard fired, not that
# there was nothing to draw.
class TextIO:
    name: str
    mode: str

    def close(self) -> None: ...
