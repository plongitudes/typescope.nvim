# Plays the role of the typeshed stub: the annotated def the declaration
# request resolves to. (.py rather than .pyi only so the mock server's glob
# picks it up; the parse path is identical.)
def ask(prompt: str = "? ", echo: bool = False) -> str: ...
