# The README demo. Recorded in Ghostty with KeyCastr on screen, from the repo
# root:
#
#   demo/record.sh && demo/encode.sh
#
# demo/play.js types this tape into a Ghostty window, and ffmpeg captures the
# window (KeyCastr overlay included) from Show to the end. Only the VHS
# commands play.js knows are used: Type (with @speed), Sleep, Hide/Show, the
# named keys and Ctrl+<key>. The Set lines are VHS's; record.sh configures
# Ghostty to match them. `vhs demo/typescope.tape` still plays it, without
# KeyCastr, as a quick preview.
#
# Needs: the release oracle (scripts/build-oracle.sh --release), basedpyright
# (mason or PATH), gruvbox-baby under nvim's lazy dir, uv (for demo/.venv),
# KeyCastr, and `ollama serve` running with qwen2.5-coder:3b pulled. The `e`
# beat's output comes from the model, so it differs run to run.

# VHS-only (the preview); record.sh captures to demo/capture.mkv
Output demo/frames/

Set Shell zsh
Set FontFamily "FantasqueSansM Nerd Font"
Set FontSize 28
Set Columns 100
Set Rows 28
Set Padding 32
Set TypingSpeed 70ms
Set CursorBlink false
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
Sleep 1500ms

# moves between beats go quickly; the hover beats take their time

# --- K on ServerConfig: the three panes, walked three levels down -----------
# G scrolls (snacks.scroll, 700ms); keys typed during the animation are lost
Type@40ms "G"
Sleep 900ms
Type@40ms "k0fS"
Sleep 400ms
Type "K"
Sleep 2500ms
# e on host: no default, so the model has something to say
Type "e"
Sleep 5s
Type "j"
Sleep 600ms
Type "j"
Sleep 600ms
Type "l"
Sleep 1200ms
# level stays open; walk down through its members to retry
Type@120ms "jjjj"
Sleep 400ms
Type "l"
Sleep 1000ms
Type@150ms "jj"
Sleep 400ms
Type "l"
# the deepest level: hold long enough to read
Sleep 2s
Type "q"
Sleep 500ms

# --- K on relationship(): 38 parameters, unions, an 1100-line docstring -----
# zt leaves the frame the room below the call; it scrolls too
Type@40ms "88Gzt"
Sleep 900ms
Type@40ms "$b"
Sleep 400ms
Type "K"
Sleep 3s
# the header is elided (…+N); s shows the whole signature over the frame
Type "s"
Sleep 3s
Type "s"
Sleep 800ms
# argument is a union; down into one of its branches
Type "j"
Sleep 500ms
Type "l"
Sleep 2s
Type "H"
Sleep 800ms
# the docstring view opens at the hovered param's :param section, and jumps
# to the next one with every row
Type "d"
Sleep 2500ms
Type "j"
Sleep 1500ms
Type "j"
Sleep 1500ms
Type "j"
Sleep 1500ms
Type "j"
Sleep 1500ms
# <C-d> / <C-u> scroll the docstring view by hand
Ctrl+D
Sleep 1200ms
Ctrl+D
Sleep 1200ms
Ctrl+U
Sleep 1200ms
Type "d"
Sleep 1s
Type "q"
Sleep 500ms

# --- insert: the active parameter follows the typing ------------------------
Type@40ms "G"
Sleep 900ms
# no autopairs in the demo: type the pair, step inside, as autopairs would
Type "o"
Enter
Type "serve()"
Left
Sleep 1000ms
Type "cfg, "
Sleep 1000ms
Type "routes, "
Sleep 1000ms
Type "level=LogLevel.DEBUG"
Sleep 1500ms
Escape
Sleep 500ms

# --- nested calls: the surface follows the innermost one ---------------------
Type "o"
Type "start()"
Left
Sleep 1000ms
Type "ServerConfig()"
Left
Sleep 1000ms
Type `"0.0.0.0"`
Sleep 800ms
Right
Type ", User()"
Left
Sleep 1000ms
Type `"ada", "ada@example.com"`
Sleep 1500ms
Escape
Sleep 500ms

# --- out, back to the frame it started on ------------------------------------
Type ":q!"
Sleep 400ms
Enter
Sleep 300ms
Type "clear"
Enter
Sleep 1s
