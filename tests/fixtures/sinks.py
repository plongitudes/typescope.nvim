# Mimics loguru's runtime module (_logger.py): untyped implementation code.
# The real signatures live in sinks_stub.py, playing the .pyi role — pyright's
# source mapper sends definition here; declaration answers from the stub.


def attach(sink, *, level=0, colorize=False):
    """Register a sink for log records.

    Parameters
    ----------
    sink : file-like object or str
        Destination that receives the formatted records.
    level : int, optional
        Minimum severity to accept.
    colorize : bool, optional
        Whether markup tags become ansi colors.
    """
    ...
