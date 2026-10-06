# Stands in for an installed package with no py.typed whose stubs pyrefly
# bundles: the interface is pyrefly's bundled first.pyi, five @overloads
# generic over _T/_S (typescope.nvim-7zd), and this is the runtime module.


def first(iterable, default=None, key=None):
    """Return the first true value of the iterable, or default."""
    return next(filter(key, iterable), default)
