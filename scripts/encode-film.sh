#!/usr/bin/env bash
# Encodes the frame folders from `Polso --film <frames>` into README media: animated WebP (GitHub renders it,
# and it's 3-13x smaller than GIF with no 256-colour banding on the glows) plus an MP4 of the hero.
set -euo pipefail
frames="${1:?frames dir}"; out="${2:?output dir}"
mkdir -p "$out"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

encode() { # clip width
  local clip=$1 w=$2
  mkdir -p "$tmp/$clip"
  ffmpeg -loglevel error -y -framerate 30 -i "$frames/$clip/%04d.png" -vf "fps=25,scale=$w:-1:flags=lanczos" "$tmp/$clip/%04d.png"
  img2webp -loop 0 -lossy -q 92 -m 4 -d 40 "$tmp/$clip"/*.png -o "$out/$clip.webp" >/dev/null 2>&1
  echo "$clip: webp $(du -h "$out/$clip.webp" | cut -f1)"
}

encode hero 960
encode indicators 600
encode alerts 760
ffmpeg -loglevel error -y -framerate 30 -i "$frames/hero/%04d.png" -c:v libx264 -pix_fmt yuv420p -crf 18 -preset slow \
  -movflags +faststart "$out/hero.mp4"
echo "hero: mp4 $(du -h "$out/hero.mp4" | cut -f1)"
