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
pad=32         # the tape's Padding
bg=0x282828    # the tape's Theme background
gif_width=900  # about the README column's width; wider only adds bytes

# the tape sets Columns x Rows, so the canvas is the text layer plus padding
IFS=x read -r w h < <(ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0:s=x frames/frame-text-00001.png)
size=$(((w + 2 * pad + 1) / 2 * 2))x$(((h + 2 * pad + 1) / 2 * 2)) # yuv420p needs even sizes

inputs=(-framerate "$fps" -i frames/frame-text-%05d.png -framerate "$fps" -i frames/frame-cursor-%05d.png)
stack="color=c=$bg:s=$size:r=$fps[bg];[bg][0]overlay=(W-w)/2:(H-h)/2:shortest=1[t];[t][1]overlay=(W-w)/2:(H-h)/2"

# mp4 at the full 2x render: uploaded to GitHub by hand (see CONTRIBUTING.md)
ffmpeg -y -v error "${inputs[@]}" -filter_complex "$stack" \
  -c:v libx264 -preset veryslow -crf 16 -tune animation \
  -pix_fmt yuv420p -movflags +faststart typescope.mp4

# gif scaled down from the 2x render (sharper than rendering it small), at a
# lower frame rate: it autoplays in the README, so size matters more
ffmpeg -y -v error "${inputs[@]}" -filter_complex \
  "$stack,fps=25,scale=$gif_width:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
  typescope.gif

ls -lh typescope.mp4 typescope.gif
