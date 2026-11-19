# AGENTS.md

Instructions for coding agents working on this repository. `AGENT.md` (no S) is something else: the prompt of the agent inside the app; change it only when the in-app agent's behavior should change.

PhotoHub is a native macOS app (Swift, SwiftUI, a Swift package without an Xcode project) that catalogs a photo archive in iCloud Drive together with the Photos library. A Python backend in `.venv` still builds the catalog and runs actions; the [roadmap](ROADMAP.md) moves it into Swift.

## Repository map

| Path | What it is |
|---|---|
| `App/Package.swift` | Swift package, macOS 13+, tools 5.10; two executables |
| `App/Sources/PhotoHub/` | the app. `Model.swift` state and navigation, `Catalog.swift` SQLite reading, `Views.swift` window, `Removal.swift` deletion and Trash, `Hidden.swift`, `Snapshot.swift` + `SnapshotOptions.swift` self-snapshot mode, `AppPaths.swift` data folder and `PHOTOHUB_NO_PHOTOS` |
| `App/Sources/PhotoHubAnalyzer/` | command-line recognition tool (Vision, SFace in Core ML), see `docs/recognition.md` |
| `App/Resources/en.lproj`, `ru.lproj` | `Localizable.strings`, `Localizable.stringsdict` (plurals), `Calendar.*`, `InfoPlist.strings` |
| `App/Resources/AppIcon.icns` | icon, made by `scripts/make_icon.py` |
| `backend/photohub/` | Python: `catalog.py` (catalog build), `tags.py` (trips, places, people, copies), `cli.py` (the `photohub` command), `config.py` (paths) |
| `backend/requirements.txt` | pinned backend dependencies exported from `uv.lock`, for installs without uv |
| `scripts/` | `install.sh` (everything in one command), `build_app.sh` (assemble, sign, install), `check.sh` (tests), `demo.sh` + `demo/`, `screenshots.sh`, `rebuild_catalog.sh`, `local.env.example` |
| `docs/` | `development.md` (architecture, data files, all snapshot steps), `recognition.md`, `images/` (README screenshots) |
| `tools/faces/` | how the SFace model was fetched and converted; not needed for builds |
| `GUIDE.md`, `ROADMAP.md`, `CONTRIBUTING.md` | user guide, plan, contribution rules |

## Prerequisites

- macOS 13+ (developed on macOS 15, Apple silicon), Xcode Command Line Tools with Swift 5.10+ (`xcode-select --install`).
- [uv](https://docs.astral.sh/uv/) (brings Python 3.14), or Python 3.14+ with `venv` and pip.
- ExifTool (`brew install exiftool`) for `photohub scan`, the demo and screenshots. The app and the catalog build work without it.
- Optional: `pngquant` for smaller screenshots.

## Build, run, test

```sh
scripts/install.sh --no-install   # everything, nothing installed: .venv, release build, signed build/PhotoHub.app
uv sync --locked                  # .venv with the photohub command (editable install of backend/)
swift build --package-path App    # debug build of PhotoHub and PhotoHubAnalyzer
swift build -c release --package-path App                       # release, both products
swift build -c release --package-path App --product PhotoHubAnalyzer
make test                         # scripts/check.sh, see below
```

- The Swift build folder is `App/.build` of the checkout, so separate worktrees never share it. Two builds at once in the same checkout need their own folder: `swift build --package-path App --scratch-path "$PWD/.build-<name>"` (and `scripts/check.sh --scratch-path …`).
- With only the Command Line Tools installed, `swift build` prints "could not determine XCTest paths"; it is harmless.
- `make` lists the targets: `install`, `build`, `app`, `demo`, `screenshots`, `test`, `clean`.
- After changing dependencies in `pyproject.toml`: `uv lock`, then `uv export --locked --no-dev --no-emit-project --format requirements-txt > backend/requirements.txt`.

### Tests: `scripts/check.sh`

There is no XCTest target. `scripts/check.sh` (`make test`) runs everything against temporary folders and never touches the real catalog or the installed app:

1. `backend/requirements.txt` matches `uv.lock`;
2. the backend compiles and imports, `photohub <command> --help` works for every command;
3. every `.strings` / `.stringsdict` parses, has no duplicate keys, and `en.lproj` and `ru.lproj` have the same keys;
4. a debug build of both products;
5. the Removal self-test: a scratch ad-hoc copy of the app (`com.example.photohub.selftest`) runs `deletetest:flow` in snapshot mode on a temporary archive; files go to the Trash and must all be put back.

A full run takes a minute or two; `--no-ui` skips step 5 (CI does that).

Other self-tests are snapshot steps (see `docs/development.md`): `deletetest[:options]`, `exporttest`, `trashtest:path`. They create, trash or export real files in whatever archive the app is pointed at; run them only against the demo or a temporary archive (`PHOTOHUB_ARCHIVE`), never against the owner's archive unless asked.

### Demo library

```sh
scripts/demo.sh                    # builds /tmp/photohub-demo and opens a separate demo app
PHOTOHUB_DEMO_DIR=/tmp/photohub-demo-$USER-x scripts/demo.sh --no-app   # library and catalog only
scripts/demo.sh --analyze          # also runs the analyzer on it
```

The demo has its own data folder, archive and bundle id (`com.example.photohub.demo`, `PHOTOHUB_DEMO_BUNDLE_ID`), uses `PHOTOHUB_NO_PHOTOS=1`, and `demo.sh` deletes and recreates `$PHOTOHUB_DEMO_DIR/support` on every run. When another agent may be using `/tmp/photohub-demo` (screenshots run it), set your own `PHOTOHUB_DEMO_DIR`; copy its `cache/` folder to skip the downloads.

### Snapshot mode: checking the UI without clicking

The app captures its own window: `PHOTOHUB_SNAPSHOT=<out>` and `PHOTOHUB_SCOPES="step;step|action"` write `<out>-N.png` and `<out>-N.txt` (title, selection, history, toolbar) per step, then the app quits. Windows are invisible unless `PHOTOHUB_SNAPSHOT_VISIBLE=1`. `PHOTOHUB_APPEARANCE=light|dark`, `PHOTOHUB_SNAPSHOT_SIZE=WxH` (window content size). `PHOTOHUB_HIDDEN_UNLOCKED=1` treats Hidden as unlocked (snapshot mode only; otherwise Hidden stays locked and Touch ID is never asked). All steps and actions are listed in `docs/development.md`.

Run it on a scratch copy of the app, not on `/Applications/PhotoHub.app`:

```sh
B=/tmp/photohub-check-$$
PHOTOHUB_LOCAL_ENV= PHOTOHUB_BUNDLE_ID=com.example.photohub.check PHOTOHUB_SIGN_IDENTITY=- \
  PHOTOHUB_INSTALL_DIR=$B PHOTOHUB_SUPPORT=$B/support scripts/build_app.sh
D=/tmp/photohub-demo
for lang in en ru; do
  defaults write com.example.photohub.check AppleLanguages -array $lang
  for look in light dark; do
    open -n -W -a $B/PhotoHub.app --env PHOTOHUB_SUPPORT=$D/support --env PHOTOHUB_ARCHIVE=$D/archive \
      --env PHOTOHUB_CATALOG=$D/support/catalog.sqlite --env PHOTOHUB_INDEX=$D/support/hash_index.sqlite \
      --env PHOTOHUB_NO_PHOTOS=1 --env PHOTOHUB_APPEARANCE=$look --env PHOTOHUB_SNAPSHOT_SIZE=1150x720 \
      --env PHOTOHUB_SNAPSHOT=$B/$lang-$look --env "PHOTOHUB_SCOPES=home;root:2025/2025-06-12 Lisbon|select"
  done
done
```

Then look at the PNGs. Afterwards: `defaults delete com.example.photohub.check`, `lsregister -u $B/PhotoHub.app` (`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`), `rm -rf $B`. Steps that change data (`hidefolder=`, `setlabel=`, …) need a copy of the catalog (`PHOTOHUB_CATALOG`) or the demo.

Verify every UI change this way: both languages, light and dark, and the minimum window size 1150 × 720 (`ContentView` minimum in `Views.swift`) as well as a large one (1500 × 950). Long Russian strings are the usual breakage.

`scripts/screenshots.sh [out]` rebuilds the demo and regenerates `docs/images/*.png` for the README.

## Install and signing

- `scripts/install.sh` checks the tools, sets up `.venv`, offers to create a self-signed "PhotoHub Local Signing" identity, writes `scripts/local.env` only if it does not exist, builds in release mode and installs through `scripts/build_app.sh`. `--help` lists the options (`--no-install`, `--user`, `--dest`, `--demo`, `--ad-hoc`, `--pip`, `--yes`).
- `scripts/build_app.sh` writes the checkout path to `<data folder>/project_path.txt` (the app runs `.venv/bin/photohub` from there), assembles `PhotoHub.app`, signs and installs it, and quits and reopens a PhotoHub running from the same place.
- `scripts/local.env` (gitignored) holds the owner's bundle id, signing identity, `PHOTOHUB_BLOCKED_IDENTITIES`, install folder. Environment variables win over it; `PHOTOHUB_LOCAL_ENV=` ignores it. Never edit the owner's `local.env`.
- macOS ties Photos, Full Disk Access and Automation permissions to the bundle id and signature. Ad-hoc builds lose them on every rebuild; a stable identity keeps them.
- Never sign with a revoked or blocked identity: Gatekeeper then treats the app as malware and moves it to the Trash. `build_app.sh` refuses identities in `PHOTOHUB_BLOCKED_IDENTITIES`; `install.sh` refuses revoked ones.
- For any test build use a scratch bundle id, `PHOTOHUB_INSTALL_DIR` in a temp folder, `PHOTOHUB_SUPPORT` in a temp folder (so the owner's `project_path.txt` is not rewritten) and `PHOTOHUB_LOCAL_ENV=`. Never overwrite `/Applications/PhotoHub.app` and never quit the owner's running PhotoHub unless asked.

## Where things live at runtime

`~/Library/Application Support/PhotoHub`, or `PHOTOHUB_SUPPORT`:

| File | What it holds |
|---|---|
| `catalog.sqlite` | the catalog: `item` (a shot), `member` (its files), tags, albums, and user data that survives rebuilds (`mark`, `user_tag`, `tag_override`, `flag`, `date_override`, `hidden_item`, `hidden_folder`, …) |
| `hash_index.sqlite` | SHA-256 per archive file |
| `thumbs/`, `previews/` | 640 px and 2048 px JPEGs named by the SHA-1 of the archive path |
| `vision.sqlite` | the analyzer's labels, fingerprints, faces, embeddings |
| `palettes.json` | cached color palettes of shots, for the tinted glass backgrounds |
| `config.json` | `archive_root`, `container_folders`, `me_folder` |
| `context.json`, `journal.jsonl`, `project_path.txt` | what is open (for the in-app agent), the move log for undo, where the checkout is |

App preferences are in `defaults` under the bundle id. Environment overrides (`PHOTOHUB_ARCHIVE`, `PHOTOHUB_CATALOG`, `PHOTOHUB_INDEX`, `PHOTOHUB_NO_PHOTOS`, …) are listed in `docs/development.md`.

## Project rules

- **English** in code, docs, commits and GitHub. Russian docs live only in `docs/ru/` (gitignored).
- **Every UI string in both `en.lproj` and `ru.lproj`.** Plurals go to `Localizable.stringsdict`, never built by string concatenation. No duplicate keys. `scripts/check.sh` checks parity and duplicates.
- **No explanatory comments or docstrings** in code, tests or scripts. The reasoning goes into the commit message. A script's usage text is fine.
- **Commits:** Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`, `ci:`), lowercase and imperative after the colon. No `Co-Authored-By` or "Generated with" trailers. One finished change per commit.
- **Git:** never push, never amend, never rebase or squash; new work is a new commit. The owner pushes. Do not change the git author (the repo uses a GitHub noreply address).
- **Parallel agents work in separate worktrees** (`git worktree add ../photohub-<task> -b <branch> main`), each with its own build folder, demo folder and scratch bundle id.
- **One confirmation per destructive action** and no "done" alerts: the result is a toast with Undo (`DeletionToast` in `ShotActions.swift`). Nothing is deleted or moved without that confirmation; deleted items go to the Trash or "Recently Deleted".
- **A duplicate is only a byte-identical file** (same SHA-256). Edits, exports and versions of a shot are never treated as duplicates.
- **Never read archive originals.** Archive files are usually dataless iCloud files; reading their contents downloads them. Work from `previews/` and `thumbs/`, file attributes and the catalog.
- **Never write to the owner's real catalog or archive in tests.** Use the demo, a copy of the catalog (`PHOTOHUB_CATALOG`) or temporary folders.
- **Item ids change on every catalog rebuild;** `item.key` is stable. Store and look up shots by key.
- **Offline:** no network calls, telemetry or uploads.
