#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH=""
UI=1
BUNDLE_ID="com.example.photohub.selftest"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

usage() {
  cat <<EOF
usage: scripts/check.sh [--scratch-path DIR] [--no-ui]

Checks this checkout without touching your catalog, archive or installed app:
  1. backend/requirements.txt matches uv.lock (when uv is installed)
  2. the Python backend compiles, imports and its photohub command starts
  3. App/Resources: every .strings and .stringsdict file parses, has no duplicate keys,
     and en.lproj and ru.lproj have the same keys
  4. a debug build of PhotoHub and PhotoHubAnalyzer
  5. the Removal self-test: a scratch copy of the app ($BUNDLE_ID, ad-hoc) runs
     "deletetest:flow" in snapshot mode on a temporary archive and must put every file back,
     also from a mocked iCloud Drive Trash

  --scratch-path DIR   Swift build folder (default App/.build)
  --no-ui              skip step 5, for machines without a logged-in GUI session
EOF
}

while (( $# )); do
  case "$1" in
    --scratch-path)
      (( $# > 1 )) || { usage >&2; exit 2; }
      SCRATCH="${2:A}"
      shift
      ;;
    --no-ui) UI=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export PHOTOHUB_SUPPORT="$WORK/support"
export PHOTOHUB_ARCHIVE="$WORK/archive"
export PHOTOHUB_CATALOG="$WORK/support/catalog.sqlite"
export PHOTOHUB_INDEX="$WORK/support/hash_index.sqlite"
export PHOTOHUB_NO_PHOTOS=1
mkdir -p "$PHOTOHUB_SUPPORT" "$PHOTOHUB_ARCHIVE/inbox"
typeset -a scratch_args
[[ -n "$SCRATCH" ]] && scratch_args=(--scratch-path "$SCRATCH")

print "==> requirements"
if command -v uv >/dev/null; then
  (cd "$ROOT" && uv lock --check --quiet)
  (cd "$ROOT" && uv export --locked --no-dev --no-emit-project --format requirements-txt --quiet) \
    | diff -q - "$ROOT/backend/requirements.txt" >/dev/null \
    || { print -u2 "backend/requirements.txt is out of date: uv export --locked --no-dev --no-emit-project --format requirements-txt > backend/requirements.txt"; exit 1; }
  print "    ok uv.lock and backend/requirements.txt"
else
  print "    skipped: uv is not installed"
fi

print "==> python"
PY="$ROOT/.venv/bin/python"
[[ -x "$PY" ]] || { print -u2 ".venv is missing: run uv sync (or scripts/install.sh --no-install)"; exit 1; }
"$PY" -m compileall -q "$ROOT/backend/photohub" "$ROOT/scripts/demo" "$ROOT/scripts/make_icon.py"
"$PY" -I -c "import photohub.catalog, photohub.cli, photohub.config, photohub.fingerprint, photohub.photos_import, photohub.tags"
"$ROOT/.venv/bin/photohub" --help >/dev/null
for command in context sql tag tags hide unhide flag move date copies folders undo rebuild rate pick thumbs scan phone; do
  "$ROOT/.venv/bin/photohub" "$command" --help >/dev/null
done
print "    ok $("$PY" -c 'import platform; print("Python", platform.python_version())')"

print "==> localization"
RES="$ROOT/App/Resources"
strings_keys() { grep -oE '^"([^"\\]|\\.)*"' "$1" | sort; }
dict_keys() { plutil -convert json -o - "$1" | "$PY" -c 'import json, sys; print("\n".join(sorted(json.load(sys.stdin))))'; }
for file in "$RES"/*.lproj/*.strings "$RES"/*.lproj/*.stringsdict; do
  plutil -lint -s "$file" || exit 1
done
for file in "$RES"/*.lproj/*.strings; do
  duplicates="$(strings_keys "$file" | uniq -d)"
  [[ -z "$duplicates" ]] || { print -u2 "duplicate keys in ${file#$ROOT/}:"; print -u2 -- "$duplicates"; exit 1; }
done
for file in "$RES"/en.lproj/*.strings "$RES"/en.lproj/*.stringsdict; do
  other="$RES/ru.lproj/${file:t}"
  [[ -f "$other" ]] || { print -u2 "missing ${other#$ROOT/}"; exit 1; }
  if [[ "$file" == *.strings ]]; then
    diff <(strings_keys "$file") <(strings_keys "$other") >/dev/null || { print -u2 "en and ru keys differ in ${file:t}:"; diff <(strings_keys "$file") <(strings_keys "$other") >&2; exit 1; }
  else
    diff <(dict_keys "$file") <(dict_keys "$other") >/dev/null || { print -u2 "en and ru keys differ in ${file:t}:"; diff <(dict_keys "$file") <(dict_keys "$other") >&2; exit 1; }
  fi
done
print "    ok en.lproj and ru.lproj"

print "==> swift build (debug)"
swift build --package-path "$ROOT/App" "${scratch_args[@]}" 2>&1 \
  | awk '/^warning: could not determine XCTest paths/ { skip = 1; next } skip && /^[[:space:]]/ { next } { skip = 0; print }'
BIN="$(swift build --package-path "$ROOT/App" "${scratch_args[@]}" --show-bin-path 2>/dev/null)"
[[ -x "$BIN/PhotoHub" && -x "$BIN/PhotoHubAnalyzer" ]]
"$BIN/PhotoHubAnalyzer" help >/dev/null
print "    ok $BIN"

if (( UI )); then
  print "==> removal self-test"
  PHOTOHUB_LOCAL_ENV= PHOTOHUB_BUNDLE_ID="$BUNDLE_ID" PHOTOHUB_SIGN_IDENTITY=- PHOTOHUB_INSTALL_DIR="$WORK/app" \
    "$ROOT/scripts/build_app.sh" >/dev/null 2>&1
  APP="$WORK/app/PhotoHub.app"
  open -n -W -a "$APP" --env PHOTOHUB_SUPPORT="$PHOTOHUB_SUPPORT" --env PHOTOHUB_ARCHIVE="$PHOTOHUB_ARCHIVE" \
    --env PHOTOHUB_CATALOG="$PHOTOHUB_CATALOG" --env PHOTOHUB_INDEX="$PHOTOHUB_INDEX" --env PHOTOHUB_NO_PHOTOS=1 \
    --env PHOTOHUB_SNAPSHOT="$WORK/shot" --env "PHOTOHUB_SCOPES=deletetest:flow,dir=inbox;home"
  "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  REPORT="$WORK/shot-deletetest.txt"
  [[ -f "$REPORT" ]] || { print -u2 "no self-test report"; exit 1; }
  failed=0
  for expected in "accepted put back: 3 of 3, present 111, same content true" \
      "archive only put back: 3 of 3, present 111, same content true" "left in archive: 000" \
      "non-main version scope ok: true" "main version scope ok: true" "photos version scope ok: true" \
      "undo history ok: true" "history cap: kept 20, dropped 5, ok: true" "scope files left: 0000" \
      "mock renamed duplicates ok: true" "mock occupied ok: true" "mock keep both: DSCF3121 2.RAF, ok: true" \
      "attempts 2, present true, ok: true" "mock missing ok: true" "done"; do
    grep -qF "$expected" "$REPORT" || { print -u2 "missing in the report: $expected"; failed=1; }
  done
  [[ -s "$WORK/shot-1.png" ]] || { print -u2 "the app did not capture its window"; failed=1; }
  if (( failed )); then
    sed 's/^/    /' "$REPORT" >&2
    exit 1
  fi
  print "    ok deletetest:flow, window captured"
fi

print "all checks passed"
