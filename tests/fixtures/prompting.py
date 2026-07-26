# Mimics the stdlib getpass.py shape: the public name is bound by a
# module-level conditional assignment, not a def.
import sys


def _unix_ask(prompt="? ", echo=False):
    ...


def _win_ask(prompt="? ", echo=False):
    ...


if sys.platform == "win32":
    ask = _win_ask
else:
    ask = _unix_ask
