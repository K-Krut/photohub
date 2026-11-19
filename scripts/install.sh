#!/bin/zsh
set -euo pipefail
autoload -U is-at-least

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_ENV="${PHOTOHUB_LOCAL_ENV-$ROOT/scripts/local.env}"
KEYCHAIN="${PHOTOHUB_SIGN_KEYCHAIN:-}"
IDENTITY_NAME="PhotoHub Local Signing"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
INSTALL=1
DEMO=0
YES=0
ADHOC=0
USE_PIP=0
DEST=""

usage() {
  cat <<EOF
usage: scripts/install.sh [options]

Builds PhotoHub from this checkout and installs it, on any Mac with macOS 13 or later:
checks the tools it needs, sets up the Python backend in .venv, creates a local
code-signing identity if you want one, builds the app and the analyzer in release
mode, signs PhotoHub.app with scripts/build_app.sh and installs it.
Running it again updates everything in place.

options:
  --no-install   build and sign PhotoHub.app into build/ without installing it
  --user         install into ~/Applications instead of /Applications
  --dest DIR     install into DIR
  --demo         afterwards build the demo library and open the demo app (scripts/demo.sh)
  --ad-hoc       do not create a local signing identity; sign ad-hoc
  --pip          set up .venv with python3 -m venv and pip even when uv is installed
  -y, --yes      answer yes to every question (Homebrew installs, the signing identity)
  -h, --help     show this help

environment:
  PHOTOHUB_LOCAL_ENV       settings file (default scripts/local.env; empty: none). It is
                           created once from scripts/local.env.example and never changed
  PHOTOHUB_BUNDLE_ID       bundle identifier, see GUIDE.md
  PHOTOHUB_SIGN_IDENTITY   signing identity; "-" signs ad-hoc
  PHOTOHUB_SIGN_KEYCHAIN   keychain for the signing identity (default: the login keychain)
  PHOTOHUB_SIGN_KEYCHAIN_PASSWORD
                           its password, to let codesign use a new key without asking
  PHOTOHUB_SUPPORT         data folder that records where this checkout is

If PhotoHub is running from the folder it is installed into, it is quit and reopened.
EOF
}

while (( $# )); do
  case "$1" in
    --no-install) INSTALL=0 ;;
    --user) DEST="$HOME/Applications" ;;
    --dest)
      (( $# > 1 )) || { usage >&2; exit 2; }
      DEST="$2"
      shift
      ;;
    --demo) DEMO=1 ;;
    --ad-hoc) ADHOC=1 ;;
    --pip) USE_PIP=1 ;;
    -y|--yes) YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$DEST" ]] && DEST="${DEST:A}"

if [[ -t 1 ]]; then
  BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' YELLOW=$'\e[33m' GREEN=$'\e[32m' RESET=$'\e[0m'
else
  BOLD="" DIM="" RED="" YELLOW="" GREEN="" RESET=""
fi
step() { print -r -- ""; print -r -- "${BOLD}==> $*${RESET}"; }
ok() { print -r -- "    ${GREEN}ok${RESET} $*"; }
note() { print -r -- "    $*"; }
warn() { print -ru2 -- "    ${YELLOW}warning:${RESET} $*"; }
die() { print -ru2 -- ""; print -ru2 -- "${RED}error:${RESET} $*"; exit 1; }
without_xctest_noise() {
  awk '/^warning: could not determine XCTest paths/ { skip = 1; next } skip && /^[[:space:]]/ { next } { skip = 0; print; fflush() }'
}
ask() {
  (( YES )) && return 0
  [[ -t 0 ]] || return 1
  local reply
  read -r "reply?    $1 [Y/n] "
  [[ -z "$reply" || "$reply" == [Yy]* ]]
}
first_executable() {
  local candidate
  for candidate in "$@"; do
    [[ -n "$candidate" && -x "$candidate" ]] && { print -r -- "$candidate"; return 0; }
  done
  return 1
}
python_version() {
  local version
  version="$("$1" -c 'import platform; print(platform.python_version())' 2>/dev/null || true)"
  [[ "$version" == <->.<->* ]] && print -r -- "$version" || print 0
}
has_identity() {
  [[ "$(identities)" == *"\"$1\""* ]]
}
identities() {
  if [[ -n "$KEYCHAIN" ]]; then
    security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null || true
  else
    security find-identity -p codesigning 2>/dev/null || true
  fi
}

create_identity() {
  local keychain="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
  local work password
  work="$(mktemp -d)"
  password="$(/usr/bin/openssl rand -hex 16)"
  cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
  if ! /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -config "$work/cert.cnf" \
      -keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null 2>&1 \
    || ! /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$IDENTITY_NAME" \
      -out "$work/identity.p12" -passout "pass:$password" >/dev/null 2>&1 \
    || ! security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null; then
    rm -rf "$work"
    return 1
  fi
  rm -rf "$work"
  if [[ -n "${PHOTOHUB_SIGN_KEYCHAIN_PASSWORD:-}" ]]; then
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PHOTOHUB_SIGN_KEYCHAIN_PASSWORD" "$keychain" >/dev/null
  fi
}

step "Checking this Mac"
[[ "$(uname -s)" == Darwin ]] || die "PhotoHub is a macOS app; this is $(uname -s)."
MACOS="$(sw_vers -productVersion)"
is-at-least 13.0 "$MACOS" || die "PhotoHub needs macOS 13 or later; this Mac has $MACOS."
ok "macOS $MACOS on $(uname -m)"

if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
  if ask "The Xcode Command Line Tools are missing. Open their installer now?"; then
    xcode-select --install >/dev/null 2>&1 || true
  fi
  die "the Xcode Command Line Tools are needed for Swift. Run: xcode-select --install
       Finish the installer, then run scripts/install.sh again."
fi
SWIFT_VERSION="$(swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9.]+).*/\1/p' | head -1)"
is-at-least 5.10 "${SWIFT_VERSION:-0}" \
  || die "PhotoHub needs Swift 5.10 or later; found ${SWIFT_VERSION:-none} at $(xcode-select -p).
       Update the Command Line Tools in System Settings → General → Software Update,
       or reinstall them: sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
ok "Swift $SWIFT_VERSION ($(xcode-select -p))"
command -v git >/dev/null || die "git is missing; it comes with the Xcode Command Line Tools: xcode-select --install"
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || warn "this folder is not a git clone; the build number will be 0"
BREW="$(first_executable "$(command -v brew || true)" /opt/homebrew/bin/brew /usr/local/bin/brew || true)"
if [[ -n "$BREW" ]]; then
  ok "Homebrew ($BREW)"
else
  note "${DIM}Homebrew not found; that is fine, it only installs uv and ExifTool for you (https://brew.sh)${RESET}"
fi

step "Python backend (.venv)"
PY_MIN="$(sed -nE 's/^requires-python *= *">=([0-9.]+)".*/\1/p' "$ROOT/pyproject.toml")"
UV="$(first_executable "$(command -v uv || true)" /opt/homebrew/bin/uv /usr/local/bin/uv "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv" || true)"
if (( ! USE_PIP )) && [[ -z "$UV" && -n "$BREW" ]] && ask "uv is not installed. Install it with Homebrew (brew install uv)?"; then
  "$BREW" install uv
  UV="$(first_executable "$(command -v uv || true)" "${BREW:h}/uv" || true)"
fi
if (( ! USE_PIP )) && [[ -n "$UV" ]]; then
  note "uv sync --locked ($UV)"
  (cd "$ROOT" && "$UV" sync --locked --quiet)
else
  PY=""
  for candidate in "$(command -v "python$PY_MIN" || true)" "$(command -v python3 || true)" \
      /opt/homebrew/bin/python3 /usr/local/bin/python3 /Library/Frameworks/Python.framework/Versions/Current/bin/python3; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if is-at-least "$PY_MIN" "$(python_version "$candidate")"; then
      PY="$candidate"
      break
    fi
  done
  [[ -n "$PY" ]] || die "the backend needs Python $PY_MIN or later and none was found.
       The easiest way is uv, which brings its own Python:
         brew install uv            (with Homebrew)
         curl -LsSf https://astral.sh/uv/install.sh | sh
       or install Python $PY_MIN from https://www.python.org/downloads/macos/
       Then run scripts/install.sh again."
  VENV_PY="$ROOT/.venv/bin/python"
  if [[ -x "$VENV_PY" ]] && ! is-at-least "$PY_MIN" "$(python_version "$VENV_PY")"; then
    note "recreating .venv with Python $PY_MIN"
    "$PY" -m venv --clear "$ROOT/.venv"
  elif [[ ! -x "$VENV_PY" ]]; then
    "$PY" -m venv "$ROOT/.venv"
  fi
  [[ -x "$VENV_PY" ]] || die "$PY could not create .venv"
  note "pip install (pinned in backend/requirements.txt) with $PY"
  "$VENV_PY" -m pip install --quiet --disable-pip-version-check --require-hashes -r "$ROOT/backend/requirements.txt"
  "$VENV_PY" -m pip install --quiet --disable-pip-version-check --no-deps -e "$ROOT"
fi
"$ROOT/.venv/bin/photohub" --help >/dev/null || die "the photohub command in .venv does not start"
ok "$("$ROOT/.venv/bin/python" -c 'import platform; print("Python", platform.python_version())'), .venv/bin/photohub"

step "ExifTool"
EXIFTOOL="$(first_executable "$(command -v exiftool || true)" /opt/homebrew/bin/exiftool /usr/local/bin/exiftool || true)"
if [[ -z "$EXIFTOOL" && -n "$BREW" ]] && ask "ExifTool is not installed. Install it with Homebrew (brew install exiftool)?"; then
  "$BREW" install exiftool
  EXIFTOOL="$(first_executable "$(command -v exiftool || true)" "${BREW:h}/exiftool" || true)"
fi
if [[ -n "$EXIFTOOL" ]]; then
  ok "ExifTool $("$EXIFTOOL" -ver) ($EXIFTOOL)"
else
  warn "ExifTool is not installed. The app and the catalog work without it, but"
  warn "'photohub scan' (previews, camera data, hashes for exact copies) and the demo do not."
  warn "Install it later with 'brew install exiftool' or the macOS package from https://exiftool.org"
  (( DEMO )) && die "--demo needs ExifTool"
fi

step "Code signing"
IDENTITY=""
FROM=""
if [[ -n "${PHOTOHUB_SIGN_IDENTITY:-}" ]]; then
  IDENTITY="$PHOTOHUB_SIGN_IDENTITY"
  FROM="PHOTOHUB_SIGN_IDENTITY"
elif [[ -n "$LOCAL_ENV" && -f "$LOCAL_ENV" ]]; then
  IDENTITY="$(zsh -c 'source "$1" >/dev/null 2>&1; print -r -- "${PHOTOHUB_SIGN_IDENTITY:-}"' _ "$LOCAL_ENV")"
  FROM="${LOCAL_ENV/#$HOME/~}"
fi
if [[ -n "$FROM" ]]; then
  note "using \"${IDENTITY:--}\" from $FROM"
elif (( ADHOC )); then
  IDENTITY="-"
elif has_identity "$IDENTITY_NAME"; then
  IDENTITY="$IDENTITY_NAME"
  note "found \"$IDENTITY_NAME\" in the keychain"
else
  note "When signed ad-hoc, every rebuild is a new app to macOS, which then asks for Photos access"
  note "again and drops Full Disk Access. A self-signed identity in your keychain avoids that."
  if ask "Create the code-signing identity \"$IDENTITY_NAME\" in ${KEYCHAIN:-your login keychain}?"; then
    if create_identity && has_identity "$IDENTITY_NAME"; then
      IDENTITY="$IDENTITY_NAME"
      ok "created \"$IDENTITY_NAME\" (self-signed, valid for 10 years, only for this Mac)"
      [[ -n "${PHOTOHUB_SIGN_KEYCHAIN_PASSWORD:-}" ]] \
        || note "On the first build macOS asks whether codesign may use the key: enter your Mac password and press \"Always Allow\"."
    else
      warn "could not create the identity; signing ad-hoc. GUIDE.md section 4 shows how to make one in Keychain Access."
      IDENTITY="-"
    fi
  else
    IDENTITY="-"
  fi
fi
[[ -n "$IDENTITY" ]] || IDENTITY="-"
if [[ "$IDENTITY" != "-" ]]; then
  line="$(identities | grep -F "\"$IDENTITY\"" | head -n 1 || true)"
  if [[ -z "$line" ]]; then
    warn "\"$IDENTITY\" is not in the keychain; build_app.sh will sign ad-hoc"
  elif [[ "$line" == *REVOKED* ]]; then
    die "the signing identity \"$IDENTITY\" is revoked. Gatekeeper moves apps signed with it to the Trash.
       Pick another one in $FROM, or add it to PHOTOHUB_BLOCKED_IDENTITIES."
  else
    ok "signing with \"$IDENTITY\""
  fi
else
  ok "signing ad-hoc"
fi
if [[ -n "$LOCAL_ENV" && ! -e "$LOCAL_ENV" ]]; then
  sed -e "s|^PHOTOHUB_BUNDLE_ID=.*|PHOTOHUB_BUNDLE_ID=${PHOTOHUB_BUNDLE_ID:-com.example.photohub}|" \
      -e "s|^PHOTOHUB_SIGN_IDENTITY=.*|PHOTOHUB_SIGN_IDENTITY=\"$IDENTITY\"|" \
      "$ROOT/scripts/local.env.example" > "$LOCAL_ENV"
  ok "wrote ${LOCAL_ENV/#$HOME/~} (your settings; edit it, the script never changes it again)"
fi

step "Building the app and the analyzer (release)"
swift build -c release --package-path "$ROOT/App" 2>&1 | without_xctest_noise
BIN_DIR="$(swift build -c release --package-path "$ROOT/App" --show-bin-path 2>/dev/null)"
ok "$BIN_DIR/PhotoHub"
ok "$BIN_DIR/PhotoHubAnalyzer"

if (( INSTALL )); then
  step "Signing and installing PhotoHub.app"
else
  step "Signing PhotoHub.app (not installing)"
  DEST="$ROOT/build"
fi
typeset -a build_env
build_env=(PHOTOHUB_SIGN_IDENTITY="$IDENTITY")
[[ -n "$DEST" ]] && build_env+=(PHOTOHUB_INSTALL_DIR="$DEST")
[[ -n "$KEYCHAIN" ]] && build_env+=(PHOTOHUB_SIGN_KEYCHAIN="$KEYCHAIN")
SCRATCH_SUPPORT=""
if (( ! INSTALL )); then
  SCRATCH_SUPPORT="$(mktemp -d)"
  build_env+=(PHOTOHUB_SUPPORT="$SCRATCH_SUPPORT")
fi
LOG="$(mktemp)"
env "${build_env[@]}" "$ROOT/scripts/build_app.sh" 2>&1 | without_xctest_noise | tee "$LOG" | sed 's/^/    /'
APP="$(sed -nE 's/^built (.*\.app) .*/\1/p' "$LOG" | tail -1)"
rm -f "$LOG"
[[ -n "$APP" && -d "$APP" ]] || die "build_app.sh did not report the app it built"
if (( ! INSTALL )); then
  "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
  rm -rf "$SCRATCH_SUPPORT"
fi

if (( DEMO )); then
  step "Demo library"
  "$ROOT/scripts/demo.sh"
fi

step "Done"
if (( INSTALL )); then
  cat <<EOF
    PhotoHub is installed: $APP
    The analyzer:          $BIN_DIR/PhotoHubAnalyzer

    Next steps:
    1. Open PhotoHub. Allow Photos access when asked; in System Settings → Privacy & Security
       give PhotoHub Full Disk Access (people, pets and hidden items from the Photos library).
    2. Settings → Archive → "Choose Folder…" and pick your photo archive
       (by default the "Photos" folder in iCloud Drive), then press "Rebuild Catalog".
       From Terminal the same is: scripts/rebuild_catalog.sh
    3. Make previews and read camera data:
         .venv/bin/photohub scan --dry-run
         .venv/bin/photohub scan
         scripts/rebuild_catalog.sh
    Keep this folder where it is: the app runs .venv/bin/photohub from it.
    To try PhotoHub without your own photos: scripts/demo.sh
    More in GUIDE.md.
EOF
else
  cat <<EOF
    Built, not installed: $APP
    The analyzer:         $BIN_DIR/PhotoHubAnalyzer
    Install it with scripts/install.sh (or --user for ~/Applications).
EOF
fi
