#!/usr/bin/env bash
# Builds the README gif and the mp4 from the frames demo/typescope.tape writes.
#
# VHS's own encoders are lossy at settings the tape can't change, so the tape
# writes lossless frames instead. They come as two transparent layers per frame
# (text, cursor) with no background or padding; this stacks them onto the
# theme's background, the way VHS does before it encodes.
#
#   vhs demo/typescope.tape && demo/encode.sh
set -euo pipefail
cd "$(dirname "$0")"

fps=30         # the tape's Framerate
size=2400x1280 # the tape's Width x Height (2x, for Retina displays)
bg=0x282828    # the tape's Theme background

inputs=(-framerate "$fps" -i frames/frame-text-%05d.png -framerate "$fps" -i frames/frame-cursor-%05d.png)
stack="color=c=$bg:s=$size:r=$fps[bg];[bg][0]overlay=(W-w)/2:(H-h)/2:shortest=1[t];[t][1]overlay=(W-w)/2:(H-h)/2"

# mp4 at full 2x resolution: uploaded to GitHub by hand (see CONTRIBUTING.md)
ffmpeg -y -v error "${inputs[@]}" -filter_complex "$stack" \
  -c:v libx264 -preset veryslow -crf 16 -tune animation \
  -pix_fmt yuv420p -movflags +faststart typescope.mp4

# gif at 1x, scaled down from the 2x render (sharper than rendering at 1x),
# at half the frame rate: it autoplays in the README, so size matters more
ffmpeg -y -v error "${inputs[@]}" -filter_complex \
  "$stack,fps=25,scale=iw/2:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
  typescope.gif

ls -lh typescope.mp4 typescope.gif
