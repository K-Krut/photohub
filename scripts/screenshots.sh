#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO="${PHOTOHUB_DEMO_DIR:-/tmp/photohub-demo}"
WIDTH="${PHOTOHUB_SCREENSHOT_WIDTH:-1600}"
APPEARANCE="${PHOTOHUB_SCREENSHOT_APPEARANCE:-dark}"
SIZE="${PHOTOHUB_SCREENSHOT_SIZE:-1200x750}"
CANVAS="${PHOTOHUB_SCREENSHOT_CANVAS:-1440x900}"
REUSE=0
OUT="$ROOT/docs/images"
for arg in "$@"; do
  case "$arg" in
    --reuse) REUSE=1 ;;
    -*) print -u2 "usage: scripts/screenshots.sh [--reuse] [out]"; exit 2 ;;
    *) OUT="$arg" ;;
  esac
done
LISBON="2025/2025-06-12 Lisbon"
HIDDEN="2026/2026-01-18 Mountains"
scenes=(
  home "home"
  trip "card:trips|select"
  folder "root:$LISBON|select"
  page "root:$LISBON|page"
  zoom "zoom"
  people "list:people"
  map "map|mapregion=41.8986,12.4769,0.035,0.05"
  calendar "calendar:month:2023-08|noinspector"
  statistics "stats|statsyears"
  tags "root:Family/2025-08-17 Maya's birthday|select3|tagsheet"
  labels "all|closesheets|label=any|sort=label"
  settings "settings:general"
  hidden "hidden|reset|sort=dateDesc"
)

(( REUSE )) && [[ -d "$DEMO/PhotoHub.app" ]] || "$ROOT/scripts/demo.sh" --no-launch
SHOTS="$(mktemp -d)"
APP_BINARY="$DEMO/PhotoHub.app/Contents/MacOS/"
trap 'pkill -f "$APP_BINARY" 2>/dev/null || true; rm -rf "$SHOTS"' EXIT
sqlite3 "$DEMO/support/catalog.sqlite" ".backup '$SHOTS/catalog.sqlite'"
demo_env=(PHOTOHUB_SUPPORT="$DEMO/support" PHOTOHUB_ARCHIVE="$DEMO/archive" PHOTOHUB_CATALOG="$SHOTS/catalog.sqlite"
  PHOTOHUB_INDEX="$DEMO/support/hash_index.sqlite" PHOTOHUB_NO_PHOTOS=1)
env "${demo_env[@]}" "$ROOT/.venv/bin/photohub" hide --keys ${(f)"$(sqlite3 "$SHOTS/catalog.sqlite" "SELECT key FROM item WHERE root = '$HIDDEN'")"}
canvas=(${(s:x:)CANVAS})
"$ROOT/.venv/bin/python" -I "$ROOT/scripts/demo/backdrop.py" "$SHOTS/backdrop.png" --size "$(( canvas[1] * 2 ))x$(( canvas[2] * 2 ))"
steps=()
app_env=()
for pair in "${demo_env[@]}"; do app_env+=(--env "$pair"); done
for name step in "${scenes[@]}"; do steps+=("$step"); done
open -n -W -a "$DEMO/PhotoHub.app" \
  "${app_env[@]}" --env PHOTOHUB_APPEARANCE="$APPEARANCE" --env PHOTOHUB_SNAPSHOT_SIZE="$SIZE" \
  --env PHOTOHUB_SNAPSHOT_VISIBLE=1 --env PHOTOHUB_SNAPSHOT_BACKDROP="$SHOTS/backdrop.png" --env PHOTOHUB_SNAPSHOT_CANVAS="$CANVAS" \
  --env PHOTOHUB_HIDDEN_UNLOCKED=1 --env PHOTOHUB_SNAPSHOT="$SHOTS/shot" --env "PHOTOHUB_SCOPES=${(j:;:)steps}" &
app=$!
index=0
inactive=()
while (( index < ${#steps} )) && kill -0 $app 2>/dev/null; do
  shot="$SHOTS/shot-$index"
  if [[ -f "$shot.ok" ]]; then
    [[ "$(<"$shot.ok")" == 0 ]] && inactive+=($index)
    index=$((index + 1))
    continue
  fi
  if [[ -f "$shot.window" && ! -f "$shot.png" ]]; then
    read -r _ x y w h < "$shot.window"
    screencapture -x -R "$x,$y,$w,$h" "$shot.png"
  fi
  sleep 0.1
done
wait $app || true

mkdir -p "$OUT"
index=0
for name step in "${scenes[@]}"; do
  src="$SHOTS/shot-$index.png"
  index=$((index + 1))
  if [[ ! -f "$src" ]]; then
    print -u2 "WARNING: no capture for $name ($step)"
    continue
  fi
  if (( ${inactive[(Ie)$((index - 1))]} )); then
    print -u2 "WARNING: PhotoHub was not the active app for $name, kept the old picture; run again"
    continue
  fi
  dst="$OUT/$name.png"
  cp "$src" "$dst"
  if (( $(sips -g pixelWidth "$dst" | awk '/pixelWidth/ {print $2}') > WIDTH )); then
    sips --resampleWidth "$WIDTH" "$dst" >/dev/null
  fi
  if command -v pngquant >/dev/null; then
    pngquant --force --skip-if-larger --quality 60-90 --speed 1 --strip --output "$dst" "$dst" || true
  fi
  print "$dst  $(sips -g pixelWidth -g pixelHeight "$dst" | awk '/pixel/ {printf "%s ", $2}')$(( $(stat -f %z "$dst") / 1024 )) KB"
done
cp "$DEMO/CREDITS.tsv" "$OUT/CREDITS.tsv"
