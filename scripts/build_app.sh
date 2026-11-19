#!/bin/zsh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_ENV="${PHOTOHUB_LOCAL_ENV-$ROOT/scripts/local.env}"
if [[ -n "$LOCAL_ENV" && -f "$LOCAL_ENV" ]]; then
  typeset -A preset
  for var in PHOTOHUB_BUNDLE_ID PHOTOHUB_SIGN_IDENTITY PHOTOHUB_BLOCKED_IDENTITIES PHOTOHUB_COPYRIGHT PHOTOHUB_INSTALL_DIR PHOTOHUB_SUPPORT; do
    [[ -n "${(P)var}" ]] && preset[$var]="${(P)var}"
  done
  source "$LOCAL_ENV"
  for var value in "${(@kv)preset}"; do typeset -g "$var=$value"; done
fi
SUPPORT="${PHOTOHUB_SUPPORT:-$HOME/Library/Application Support/PhotoHub}"
BUNDLE_ID="${PHOTOHUB_BUNDLE_ID:-com.example.photohub}"
IDENTITY="${PHOTOHUB_SIGN_IDENTITY:--}"
COPYRIGHT="${PHOTOHUB_COPYRIGHT:-© 2026 PhotoHub contributors}"
DEST="${PHOTOHUB_INSTALL_DIR:-/Applications}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

mkdir -p "$SUPPORT"
print -r -- "$ROOT" > "$SUPPORT/project_path.txt"
swift build -c release --package-path "$ROOT/App"
BIN="$(swift build -c release --package-path "$ROOT/App" --show-bin-path)/PhotoHub"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
NEW="$STAGE/PhotoHub.app"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"
cp "$ROOT/App/Resources/AppIcon.icns" "$NEW/Contents/Resources/AppIcon.icns"
for lproj in "$ROOT"/App/Resources/*.lproj; do ditto "$lproj" "$NEW/Contents/Resources/${lproj:t}"; done
cp "$BIN" "$NEW/Contents/MacOS/PhotoHub"
cat > "$NEW/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>PhotoHub</string>
<key>CFBundleDisplayName</key><string>PhotoHub</string>
<key>CFBundleExecutable</key><string>PhotoHub</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
<key>NSPhotoLibraryUsageDescription</key><string>PhotoHub shows items from the Photos library next to the archive.</string>
<key>NSAppleEventsUsageDescription</key><string>PhotoHub opens the chosen item in the Photos app and asks Finder to move archive files that are only in iCloud to the Trash.</string>
<key>NSDesktopFolderUsageDescription</key><string>PhotoHub shows the archive if it is in the Desktop folder.</string>
<key>NSDocumentsFolderUsageDescription</key><string>PhotoHub shows the archive if it is in the Documents folder.</string>
</dict></plist>
PLIST

for blocked in ${(s:;:)PHOTOHUB_BLOCKED_IDENTITIES}; do
  if [[ "$IDENTITY" == *"$blocked"* ]]; then
    print -u2 "ERROR: the signing identity \"$IDENTITY\" is listed in PHOTOHUB_BLOCKED_IDENTITIES."
    exit 1
  fi
done
if [[ "$IDENTITY" == "-" ]]; then
  print -u2 "NOTE: signing ad-hoc. macOS may ask for Photos access again after a rebuild; see GUIDE.md to sign with a local identity."
  codesign --force --timestamp=none -s - "$NEW"
elif security find-identity -p codesigning | grep -qF "\"$IDENTITY\""; then
  codesign --force --timestamp=none -s "$IDENTITY" "$NEW"
else
  print -u2 "WARNING: signing identity \"$IDENTITY\" not found in the keychain, signing ad-hoc."
  print -u2 "WARNING: macOS will ask for Photos access again after every rebuild."
  codesign --force --timestamp=none -s - "$NEW"
fi
codesign --verify --deep --strict "$NEW"

if [[ -n "$PHOTOHUB_INSTALL_DIR" ]]; then
  mkdir -p "$DEST"
elif [[ ! -w "$DEST" ]]; then
  print -u2 "WARNING: $DEST is not writable, installing to $HOME/Applications"
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi
APP="$DEST/PhotoHub.app"

running=()
for pid in $(pgrep -x PhotoHub || true); do
  cmd="$(ps -p "$pid" -o command= || true)"
  if [[ "$cmd" == "$APP/"* ]]; then
    running+=("$pid")
  fi
done
if (( ${#running} )); then
  osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
  for i in {1..30}; do
    alive=0
    for pid in $running; do kill -0 "$pid" 2>/dev/null && alive=1; done
    (( alive )) || break
    sleep 0.5
  done
  for pid in $running; do kill -0 "$pid" 2>/dev/null && kill "$pid"; done
fi

rm -rf "$APP"
ditto "$NEW" "$APP"
"$LSREGISTER" -f "$APP"

echo "built $APP $VERSION ($BUILD)"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Signature)='
codesign --verify --deep --strict "$APP" && echo "signature verified"

if (( ${#running} )); then
  open "$APP"
fi
