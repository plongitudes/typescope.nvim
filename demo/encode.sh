#!/usr/bin/env bash
# Builds the README gif and the mp4 from the capture demo/record.sh writes.
#
#   demo/record.sh && demo/encode.sh && demo/publish.sh
set -euo pipefail
cd "$(dirname "$0")"

gif_width=900 # about the README column's width; wider only adds bytes

# mp4 at the full 2x capture: uploaded to GitHub by hand (see CONTRIBUTING.md)
ffmpeg -y -v error -i capture.mkv \
  -c:v libx264 -preset veryslow -crf 16 -tune animation \
  -pix_fmt yuv420p -movflags +faststart typescope.mp4

# gif scaled down from the 2x capture (sharper than capturing it small), at a
# lower frame rate: it autoplays in the README, so size matters more
ffmpeg -y -v error -i capture.mkv -filter_complex \
  "fps=25,scale=$gif_width:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
  typescope.gif

ls -lh typescope.mp4 typescope.gif
