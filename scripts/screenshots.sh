#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO="${PHOTOHUB_DEMO_DIR:-/tmp/photohub-demo}"
OUT="${1:-$ROOT/docs/images}"
WIDTH="${PHOTOHUB_SCREENSHOT_WIDTH:-1600}"
APPEARANCE="${PHOTOHUB_SCREENSHOT_APPEARANCE:-light}"
SIZE="${PHOTOHUB_SCREENSHOT_SIZE:-1500x950}"
LISBON="2025/2025-06-12 Lisbon"
scenes=(
  home "home"
  trip "card:trips"
  folder "root:$LISBON|select"
  subfolders "folders:Family"
  page "root:$LISBON|page"
  zoom "zoom"
  people "list:people"
  map "map"
  labels "all|label=any|sort=label"
  settings "settings:catalog"
)

"$ROOT/scripts/demo.sh" --no-launch
SHOTS="$(mktemp -d)"
trap 'rm -rf "$SHOTS"' EXIT
steps=()
for name step in "${scenes[@]}"; do steps+=("$step"); done
open -n -W -a "$DEMO/PhotoHub.app" \
  --env PHOTOHUB_SUPPORT="$DEMO/support" --env PHOTOHUB_ARCHIVE="$DEMO/archive" \
  --env PHOTOHUB_CATALOG="$DEMO/support/catalog.sqlite" --env PHOTOHUB_INDEX="$DEMO/support/hash_index.sqlite" \
  --env PHOTOHUB_NO_PHOTOS=1 --env PHOTOHUB_APPEARANCE="$APPEARANCE" --env PHOTOHUB_SNAPSHOT_SIZE="$SIZE" \
  --env PHOTOHUB_SNAPSHOT="$SHOTS/shot" --env "PHOTOHUB_SCOPES=${(j:;:)steps}"

mkdir -p "$OUT"
index=0
for name step in "${scenes[@]}"; do
  src="$SHOTS/shot-$index.png"
  index=$((index + 1))
  if [[ ! -f "$src" ]]; then
    print -u2 "WARNING: no capture for $name ($step)"
    continue
  fi
  dst="$OUT/$name.png"
  cp "$src" "$dst"
  if (( $(sips -g pixelWidth "$dst" | awk '/pixelWidth/ {print $2}') > WIDTH )); then
    sips --resampleWidth "$WIDTH" "$dst" >/dev/null
  fi
  if command -v pngquant >/dev/null; then
    pngquant --force --skip-if-larger --quality 65-95 --strip --output "$dst" "$dst" || true
  fi
  print "$dst  $(sips -g pixelWidth -g pixelHeight "$dst" | awk '/pixel/ {printf "%s ", $2}')$(( $(stat -f %z "$dst") / 1024 )) KB"
done
cp "$DEMO/CREDITS.tsv" "$OUT/CREDITS.tsv"
