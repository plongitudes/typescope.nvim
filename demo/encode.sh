#!/usr/bin/env bash
# Builds the README gif and the mp4 from the capture demo/record.sh writes.
#
#   demo/record.sh && demo/encode.sh && demo/publish.sh
set -euo pipefail
cd "$(dirname "$0")"

gif_width=900 # about the README column's width; wider only adds bytes
fps=30        # the capture's rate (play.js), evened out: avfoundation's isn't steady
# GitHub's player shows an mp4's first frame until it's played, and takes no
# poster: so the first frame is this one, from the relationship() hover
poster_at=24 # seconds into the capture

# mp4 at the full 2x capture: uploaded to GitHub by hand (see CONTRIBUTING.md)
ffmpeg -y -v error -i capture.mkv -filter_complex \
  "fps=$fps,split[a][b];[a]trim=start_frame=$((poster_at * fps)):end_frame=$((poster_at * fps + 1)),setpts=PTS-STARTPTS[p];[p][b]concat=n=2:v=1" \
  -c:v libx264 -preset veryslow -crf 16 -tune animation \
  -pix_fmt yuv420p -movflags +faststart typescope.mp4

# gif scaled down from the 2x capture (sharper than capturing it small), at a
# lower frame rate: it autoplays in the README, so size matters more
ffmpeg -y -v error -i capture.mkv -filter_complex \
  "fps=25,scale=$gif_width:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
  typescope.gif

ls -lh typescope.mp4 typescope.gif
