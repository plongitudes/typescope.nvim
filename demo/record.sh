#!/usr/bin/env bash
# Records the README demo: opens a Ghostty window set up like
# demo/typescope.tape's Set lines, plays the tape into it with real keystrokes
# (demo/play.js), and captures the window, KeyCastr included, to
# demo/capture.mkv.
#
#   demo/record.sh && demo/encode.sh && demo/publish.sh
#
# Before running: KeyCastr open, Do Not Disturb on, and `ollama serve` up. Once
# the window opens, it waits while you drag KeyCastr over the window's
# bottom-right corner (only what's inside the window is captured). Hands off
# the keyboard and mouse once it plays: play.js stops if anything other than
# the demo window takes focus.
#
# The terminal this runs from needs Accessibility (keystrokes), Automation for
# System Events, and Screen Recording (ffmpeg); macOS asks on the first run.
set -euo pipefail
cd "$(dirname "$0")"
demo=$PWD
repo=$(dirname "$demo")

# SQLAlchemy for the relationship() beat
if [ ! -x .venv/bin/python ]; then
  uv venv -q -p 3.12 .venv
  uv pip install -q -p .venv/bin/python -r requirements.txt
fi

[ -x "$repo/oracle/target/release/typescope-oracle" ] || { echo "no release oracle: scripts/build-oracle.sh --release" >&2; exit 1; }
pgrep -xq KeyCastr || { echo "KeyCastr isn't running" >&2; exit 1; }
curl -sf localhost:11434/api/version >/dev/null || { echo "ollama isn't serving on :11434" >&2; exit 1; }

# the window's shell: this PATH (open doesn't pass the environment), no rc files
env=$(mktemp)
trap 'rm -f "$env"' EXIT
printf 'export PATH=%q\n' "$PATH" >"$env"

# the tape's Theme, as Ghostty palette entries
palette=()
i=0
for c in 282828 cc241d 98971a d79921 458588 b16286 689d6a a89984 928374 fb4934 b8bb26 fabd2f 83a598 d3869b 8ec07c ebdbb2; do
  palette+=("--palette=$i=#$c")
  i=$((i + 1))
done

# FontSize 28 and Padding 32 are VHS pixels: points on a 2x screen
open -na /Applications/Ghostty.app --args \
  --config-default-files=false \
  --title=typescope-demo \
  --font-family="FantasqueSansM Nerd Font" --font-size=14 \
  --window-width=100 --window-height=28 \
  --window-padding-x=16 --window-padding-y=16 --window-padding-balance=true \
  --macos-titlebar-style=hidden \
  --window-save-state=never --confirm-close-surface=false \
  --background=#282828 --foreground=#ebdbb2 --cursor-color=#ebdbb2 --selection-background=#665c54 \
  "${palette[@]}" \
  --cursor-style=block --cursor-style-blink=false --shell-integration=none \
  --working-directory="$repo" \
  --command="/bin/zsh -f -c 'source $env; exec /bin/zsh -f -i'"

# wait for the window; the shell inside it reads $env once, on start
for _ in $(seq 50); do
  sleep 0.2
  osascript -l JavaScript -e 'Application("System Events").processes.whose({name: "ghostty"})().some(p => p.windows().some(w => w.name() === "typescope-demo"))' | grep -q true && break
done
sleep 1

read -rp "Place KeyCastr over the demo window's bottom-right corner, then press Enter to record. "

status=0
osascript -l JavaScript play.js typescope.tape "$demo/capture.mkv" || status=$?

# close the demo's Ghostty instance, not the others
osascript -l JavaScript -e 'Application("System Events").processes.whose({name: "ghostty"})().filter(p => p.windows().some(w => w.name() === "typescope-demo")).map(p => p.unixId()).join(" ")' | xargs -r kill
exit $status
