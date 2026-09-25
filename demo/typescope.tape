# The README demo. Re-record after UI changes, from the repo root:
#
#   vhs demo/typescope.tape
#
# Needs: vhs, the release oracle (scripts/build-oracle.sh --release),
# basedpyright (mason or PATH), gruvbox-baby under nvim's lazy dir, and
# `ollama serve` running with qwen2.5-coder:3b pulled. The `e` beat's output
# comes from the model, so it differs run to run.

# lossless frames; demo/encode.sh makes the gif and the mp4 from them
Output demo/frames/

Set Shell zsh
Set FontFamily "FantasqueSansM Nerd Font"
Set FontSize 28
Set Width 2400
Set Height 1280
Set Padding 32
Set TypingSpeed 70ms
Set CursorBlink false
# 50 (the default) is more than VHS can capture at 2x here; frames it misses
# shorten the video instead of stretching it, so pick a rate it keeps up with
Set Framerate 30
# Ghostty's Gruvbox Dark: nvim runs transparent, so this bg is what shows
Set Theme { "name": "Gruvbox Dark", "background": "#282828", "foreground": "#ebdbb2", "cursor": "#ebdbb2", "selection": "#665c54", "black": "#282828", "red": "#cc241d", "green": "#98971a", "yellow": "#d79921", "blue": "#458588", "magenta": "#b16286", "cyan": "#689d6a", "white": "#a89984", "brightBlack": "#928374", "brightRed": "#fb4934", "brightGreen": "#b8bb26", "brightYellow": "#fabd2f", "brightBlue": "#83a598", "brightMagenta": "#d3869b", "brightCyan": "#8ec07c", "brightWhite": "#ebdbb2" }

Hide
Type "cd demo && PS1='$ ' && alias nvim='nvim --clean -u init.lua'"
Enter
# load the model so the first `e` doesn't pay a cold start
Type `curl -s localhost:11434/api/generate -d '{"model":"qwen2.5-coder:3b","keep_alive":"10m"}' >/dev/null`
Enter
Sleep 8s
Type "clear"
Enter
Sleep 500ms
Show

Sleep 1s
Type "nvim demo.py"
Sleep 300ms
Enter
# the oracle and basedpyright index; nothing on screen depends on it yet
Sleep 3s

# --- insert beat 1: the active parameter follows the typing -----------------
Type "G2k"
Sleep 500ms
Type "f(a"
Sleep 1500ms
Type "cfg, "
Sleep 1200ms
Type "routes, "
Sleep 1200ms
Type "level=LogLevel.DEBUG"
Sleep 2s
Escape
Sleep 800ms

# --- insert beat 2: the argument's type picks the overload ------------------
Type "j0f(a"
Sleep 1500ms
Type "42"
Sleep 2s
Backspace 2
Type `"ada@example.com"`
Sleep 2500ms
Escape
Sleep 800ms

# --- K on User: a glance, no descending --------------------------------------
Type "j0fU"
Sleep 500ms
Type "K"
Sleep 2500ms
Type "q"
Sleep 800ms

# --- K on ServerConfig: three levels down, docstring, example, back out -----
Type "0fS"
Sleep 500ms
Type "K"
Sleep 2500ms
# e on host: no default, so the model has something to say
Type "e"
Sleep 6s
Type "j"
Sleep 400ms
Type "j"
Sleep 700ms
Type "l"
Sleep 1500ms
Type "h"
Sleep 800ms
Type "j"
Sleep 700ms
Type "l"
Sleep 1200ms
Type "j"
Sleep 400ms
Type "j"
Sleep 700ms
Type "l"
Sleep 1500ms
Type "d"
Sleep 3s
Type "d"
Sleep 1s
Type "H"
Sleep 1500ms
Type "q"
Sleep 800ms

# --- out, back to the frame it started on ------------------------------------
Type ":q!"
Sleep 400ms
Enter
Sleep 300ms
Type "clear"
Enter
Sleep 1s
