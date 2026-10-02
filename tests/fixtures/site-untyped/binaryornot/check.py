# Stands in for an installed package with no py.typed whose stubs pyrefly
# bundles (as it does for requests): the interface is pyrefly's bundled
# check.pyi, which has no .py beside it, and this is the runtime module.


def is_binary(filename):
    """Guess whether a file is binary, documented in the runtime module."""
    return False
