#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO="${PHOTOHUB_DEMO_DIR:-/tmp/photohub-demo}"
DEMO_BUNDLE_ID="${PHOTOHUB_DEMO_BUNDLE_ID:-com.example.photohub.demo}"
ANALYZE=0
LAUNCH=1
BUILD_APP=1

usage() {
  print -u2 "usage: scripts/demo.sh [--analyze] [--no-launch] [--no-app]"
  print -u2 "  builds a demo archive of free stock photos in $DEMO and opens PhotoHub on it"
  exit 2
}
for arg in "$@"; do
  case "$arg" in
    --analyze) ANALYZE=1 ;;
    --no-launch) LAUNCH=0 ;;
    --no-app) BUILD_APP=0; LAUNCH=0 ;;
    *) usage ;;
  esac
done

DEMO="${DEMO:A}"
REAL_SUPPORT="$HOME/Library/Application Support/PhotoHub"
if [[ -z "$DEMO" || "$DEMO" == "/" || "$DEMO" == "$HOME" || "$DEMO" == "$REAL_SUPPORT"* || "$REAL_SUPPORT" == "$DEMO"* ]]; then
  print -u2 "ERROR: refusing to use $DEMO as the demo folder"
  exit 1
fi
if ! command -v exiftool >/dev/null && [[ ! -x /opt/homebrew/bin/exiftool ]]; then
  print -u2 "ERROR: exiftool not found. Install it: brew install exiftool"
  exit 1
fi

export PHOTOHUB_SUPPORT="$DEMO/support"
export PHOTOHUB_ARCHIVE="$DEMO/archive"
export PHOTOHUB_CATALOG="$DEMO/support/catalog.sqlite"
export PHOTOHUB_INDEX="$DEMO/support/hash_index.sqlite"
export PHOTOHUB_NO_PHOTOS=1
PY="$ROOT/.venv/bin/python"

[[ -x "$PY" ]] || (cd "$ROOT" && uv sync)

rm -rf "$PHOTOHUB_SUPPORT"
mkdir -p "$PHOTOHUB_SUPPORT"
print -r -- "$ROOT" > "$PHOTOHUB_SUPPORT/project_path.txt"
cat > "$PHOTOHUB_SUPPORT/config.json" <<JSON
{
  "archive_root": "$PHOTOHUB_ARCHIVE",
  "container_folders": ["Family", "Trips"]
}
JSON

"$PY" -I "$ROOT/scripts/demo/build_library.py" build --manifest "$ROOT/scripts/demo/library.tsv" \
  --cache "$DEMO/cache" --archive "$PHOTOHUB_ARCHIVE" --support "$PHOTOHUB_SUPPORT"
"$PY" -m photohub.catalog --no-tags
"$ROOT/.venv/bin/photohub" scan --workers 4
"$PY" -m photohub.catalog
"$PY" -I "$ROOT/scripts/demo/build_library.py" seed --support "$PHOTOHUB_SUPPORT" --catalog "$PHOTOHUB_CATALOG"

if (( ANALYZE )); then
  swift build -c release --package-path "$ROOT/App" --product PhotoHubAnalyzer --scratch-path "$DEMO/analyzer-build"
  "$DEMO/analyzer-build/release/PhotoHubAnalyzer" run --only archive
fi

if (( BUILD_APP )); then
  PHOTOHUB_LOCAL_ENV= PHOTOHUB_BUNDLE_ID="$DEMO_BUNDLE_ID" PHOTOHUB_SIGN_IDENTITY=- PHOTOHUB_INSTALL_DIR="$DEMO" \
    "$ROOT/scripts/build_app.sh"
  defaults write "$DEMO_BUNDLE_ID" AppleLanguages -array en
  defaults write "$DEMO_BUNDLE_ID" AppleLocale en_US
  defaults write "$DEMO_BUNDLE_ID" meName Sofia
fi

if (( LAUNCH )); then
  open -n -a "$DEMO/PhotoHub.app" --env PHOTOHUB_SUPPORT="$PHOTOHUB_SUPPORT" --env PHOTOHUB_ARCHIVE="$PHOTOHUB_ARCHIVE" \
    --env PHOTOHUB_CATALOG="$PHOTOHUB_CATALOG" --env PHOTOHUB_INDEX="$PHOTOHUB_INDEX" --env PHOTOHUB_NO_PHOTOS=1
  print "PhotoHub demo is open. Data: $DEMO. Photo credits: $DEMO/CREDITS.tsv"
fi
