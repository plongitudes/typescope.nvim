# The README's stills. Re-shoot after UI changes, from the repo root:
#
#   vhs demo/shots.tape && demo/publish.sh
#
# Needs what demo/typescope.tape needs, minus ollama: stills use heuristic
# examples, so they come out the same every run.

# the recording itself is thrown away; only the Screenshot lines matter
Output demo/shots/.discard.gif

Set Shell zsh
Set FontFamily "FantasqueSansM Nerd Font"
Set FontSize 28
Set Columns 56
Set Rows 15
Set Padding 32
Set CursorBlink false
# Ghostty's Gruvbox Dark: nvim runs transparent, so this bg is what shows
Set Theme { "name": "Gruvbox Dark", "background": "#282828", "foreground": "#ebdbb2", "cursor": "#ebdbb2", "selection": "#665c54", "black": "#282828", "red": "#cc241d", "green": "#98971a", "yellow": "#d79921", "blue": "#458588", "magenta": "#b16286", "cyan": "#689d6a", "white": "#a89984", "brightBlack": "#928374", "brightRed": "#fb4934", "brightGreen": "#b8bb26", "brightYellow": "#fabd2f", "brightBlue": "#83a598", "brightMagenta": "#d3869b", "brightCyan": "#8ec07c", "brightWhite": "#ebdbb2" }

# Screenshot lands a beat after the command: Hide straight after it captures
# the next shot's frame instead, hence the Sleep after each one.

Hide
Type "cd demo && mkdir -p shots && export TYPESCOPE_SHOT=1 && alias nvim='nvim --clean -u init.lua'"
Enter

# README intro: the default ledger, cursor on the first row
Hide
Type "nvim shots.py"
Enter
# the oracle and basedpyright index
Sleep 4s
# the call at the top of the window, so the float opens below it
Type "Gzt0K"
Sleep 1500ms
Show
Sleep 100ms
Screenshot demo/shots/intro.png
Sleep 500ms
Hide
Type "qZQ"
Sleep 300ms

# The ledger, cursor on host
Hide
Type "nvim shots.py"
Enter
# the oracle and basedpyright index
Sleep 4s
# the call at the top of the window, so the float opens below it
Type "Gzt0K"
Sleep 1500ms
Type "j"
Sleep 500ms
Show
Sleep 100ms
Screenshot demo/shots/ledger.png
Sleep 500ms
Hide
Type "qZQ"
Sleep 300ms

# Styles: rounded
Hide
Type "TYPESCOPE_STYLE=rounded nvim shots.py"
Enter
# the oracle and basedpyright index
Sleep 4s
# the call at the top of the window, so the float opens below it
Type "Gzt0K"
Sleep 1500ms
Show
Sleep 100ms
Screenshot demo/shots/style-rounded.png
Sleep 500ms
Hide
Type "qZQ"
Sleep 300ms

# Styles: unicode
Hide
Type "TYPESCOPE_STYLE=unicode nvim shots.py"
Enter
# the oracle and basedpyright index
Sleep 4s
# the call at the top of the window, so the float opens below it
Type "Gzt0K"
Sleep 1500ms
Show
Sleep 100ms
Screenshot demo/shots/style-unicode.png
Sleep 500ms
Hide
Type "qZQ"
Sleep 300ms

# Styles: ascii
Hide
Type "TYPESCOPE_STYLE=ascii nvim shots.py"
Enter
# the oracle and basedpyright index
Sleep 4s
# the call at the top of the window, so the float opens below it
Type "Gzt0K"
Sleep 1500ms
Show
Sleep 100ms
Screenshot demo/shots/style-ascii.png
Sleep 500ms
Hide
Type "qZQ"
Sleep 300ms

# Styles: minimal
Hide
Type "TYPESCOPE_STYLE=minimal nvim shots.py"
Enter
# the oracle and basedpyright index
Sleep 4s
# the call at the top of the window, so the float opens below it
Type "Gzt0K"
Sleep 1500ms
Show
Sleep 100ms
Screenshot demo/shots/style-minimal.png
Sleep 500ms
Hide
Type "qZQ"
Sleep 300ms
