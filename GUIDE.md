# PhotoHub guide

How to install, build and run PhotoHub, what it needs from macOS, and how to use it day to day. For the architecture, the data files and the UI self-check mode, see [docs/development.md](docs/development.md).

- [1. Prerequisites](#1-prerequisites)
- [2. Get the code](#2-get-the-code)
- [3. Choose the archive folder](#3-choose-the-archive-folder)
- [4. Build, sign and install](#4-build-sign-and-install)
- [5. Permissions](#5-permissions)
- [6. First catalog build and scan](#6-first-catalog-build-and-scan)
- [7. Daily use](#7-daily-use)
- [8. Recognition: the analyzer and the face model](#8-recognition-the-analyzer-and-the-face-model)
- [9. The agent](#9-the-agent)
- [10. Troubleshooting](#10-troubleshooting)
- [11. Uninstall and clean up](#11-uninstall-and-clean-up)

## 1. Prerequisites

| What | Why | How |
|---|---|---|
| macOS 13 or later | the app | developed and tested on macOS 15, Apple silicon |
| Xcode Command Line Tools | Swift compiler | `xcode-select --install` (full Xcode works too) |
| uv | Python 3.14 environment for the catalog backend | `brew install uv` or see [docs.astral.sh/uv](https://docs.astral.sh/uv/); Python 3.14 with pip works too |
| ExifTool | camera data and previews during the scan, the demo | `brew install exiftool`; the app and the catalog build work without it |
| Claude Code CLI (optional) | the agent panel | [claude.com/claude-code](https://claude.com/claude-code), then log in once in Terminal |

## 2. Get the code

```sh
git clone https://github.com/K-Krut/photohub.git photohub
cd photohub
scripts/install.sh
```

`scripts/install.sh` (or `make install`) does sections 1, 2 and 4 in one go and can be run again at any time to update:

1. checks macOS, the Command Line Tools and Swift, and says how to fix what is missing;
2. sets up `.venv` with `uv sync --locked`, or, without uv, with Python 3.14+ and pip from the pinned `backend/requirements.txt`; offers `brew install uv` when Homebrew is there;
3. checks ExifTool and offers `brew install exiftool`;
4. offers to create the self-signed "PhotoHub Local Signing" identity in your login keychain (see section 4) and writes `scripts/local.env` if you do not have one yet; an existing `local.env` is never changed;
5. builds the app and the analyzer in release mode, then signs and installs `PhotoHub.app` with `scripts/build_app.sh`, and prints the next steps.

Options: `--user` installs into `~/Applications`, `--no-install` only builds and signs `build/PhotoHub.app`, `--demo` then opens the demo library, `--ad-hoc` skips the identity, `--yes` answers yes to every question; `scripts/install.sh --help` lists them all.

The manual way, step by step:

```sh
uv sync
scripts/build_app.sh
```

`uv sync` creates `.venv` with Python 3.14 and the `photohub` command (`.venv/bin/photohub`). The app, the scripts and the agent all call this command, so keep the project folder where it is after building; `scripts/build_app.sh` records its path.

## 3. Choose the archive folder

The archive is the folder tree with your photo files. By default PhotoHub uses `Photos` in iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/Photos`). Any local folder or external disk works too.

Change it in the app (Settings → Archive → "Choose Folder…"), or in `~/Library/Application Support/PhotoHub/config.json`:

```json
{
  "archive_root": "~/Pictures/Archive",
  "container_folders": ["Family", "Trips"],
  "me_folder": "Me"
}
```

| Key | Meaning |
|---|---|
| `archive_root` | the archive folder |
| `container_folders` | folders that hold events rather than being one, like year folders. With `["Trips"]`, the event of `Trips/2025-12 Vienna/DSCF0001.JPG` is `Trips/2025-12 Vienna`, not `Trips` |
| `me_folder` | your personal folder; "Add to Archive…" suggests `<me_folder>/<year>` for shots you are in |

A typical layout PhotoHub understands well:

```
Photos/
  2025/
    2025-06-12 Lisbon/
      DSCF0412.JPG
      DSCF0412_LR.jpg        ← an edit, stacked with the original
      RAW/DSCF0412.RAF
      Export/DSCF0412.jpg    ← an export, stacked too
  Trips/
    2025-12 Vienna/
  Family/
    Pets/
```

Year folders (`2025`) and container folders are walked through; the first other folder is the event. Edits are recognized by `_LR`, `_PS`, `-Edit`, `.psd`, by folders named `Export` or `Edited`, and by the editing program in the file's EXIF.

## 4. Build, sign and install

```sh
scripts/build_app.sh
```

The script builds the release binary, assembles `PhotoHub.app`, signs it, installs it into `/Applications` (or `~/Applications` if `/Applications` is not writable), registers it with Launch Services, writes the project path into the data folder, and reopens PhotoHub if it was running. The version comes from `VERSION`, the build number is the number of git commits.

### Your settings: `scripts/local.env`

Copy `scripts/local.env.example` to `scripts/local.env` (ignored by git) and set your own values. Variables set in the environment win over the file.

| Variable | Default | Meaning |
|---|---|---|
| `PHOTOHUB_BUNDLE_ID` | `com.example.photohub` | the bundle identifier. macOS ties the Photos, Full Disk Access and Automation permissions to it, so pick one (for example `io.github.<you>.photohub`) and keep it |
| `PHOTOHUB_SIGN_IDENTITY` | `-` (ad-hoc) | a code-signing identity from your login keychain |
| `PHOTOHUB_COPYRIGHT` | `© 2026 PhotoHub contributors` | the line in About PhotoHub |
| `PHOTOHUB_BLOCKED_IDENTITIES` | empty | identities the script must never use, separated by `;` (for example a revoked certificate) |
| `PHOTOHUB_INSTALL_DIR` | `/Applications` | install somewhere else, for example for a test copy |
| `PHOTOHUB_LOCAL_ENV` | `scripts/local.env` | another settings file; empty to ignore it |

### Ad-hoc or a local signing identity

Ad-hoc signing works, but every rebuild is a "new" app for macOS, which may ask for Photos access again and drop Full Disk Access. A self-signed identity keeps the permissions across rebuilds. `scripts/install.sh` creates one for you; to make it by hand:

1. Open Keychain Access → Keychain Access menu → Certificate Assistant → Create a Certificate…
2. Name: `PhotoHub Local Signing`, Identity Type: Self-Signed Root, Certificate Type: Code Signing. Create it in the login keychain.
3. In `scripts/local.env`: `PHOTOHUB_SIGN_IDENTITY="PhotoHub Local Signing"`.
4. On the first build macOS asks whether `codesign` may use the key: enter your Mac password and press "Always Allow".

The identity is "not trusted" for distribution, which does not matter for an app you build and run yourself. Do not sign with a certificate that may be revoked: Gatekeeper treats an app with a revoked signature as malware and moves it to the Trash. Add such an identity to `PHOTOHUB_BLOCKED_IDENTITIES`.

## 5. Permissions

macOS asks for most of these the first time they are needed. All of them are in System Settings → Privacy & Security.

| Permission | What needs it | Without it |
|---|---|---|
| Photos → Full Access | showing, deleting and adding Photos items | phone shots have no previews; deleting from Photos is not possible |
| Full Disk Access → PhotoHub | reading people and pets from a copy of the Photos database; moving iCloud-only files to the Trash | no people and pets (the main screen says so); some deletions fall back to the iCloud trash or Finder |
| Automation → PhotoHub → Photos | the catalog build reads the Photos library and "Send to Photos" imports through it | the catalog build fails at the Photos step |
| Automation → PhotoHub → Finder | the last fallback for moving an iCloud-only file to the Trash | that fallback is skipped |

When you rebuild the catalog or scan from Terminal, Terminal (not PhotoHub) needs Full Disk Access and Automation.

**Without the Photos library.** If you do not use Photos, set `PHOTOHUB_NO_PHOTOS=1`: the catalog, the tags and the app then ignore the library completely, and trips come from the GPS in your files. In Terminal, `export PHOTOHUB_NO_PHOTOS=1` before running `photohub`; for the app, start it with `open -a PhotoHub --env PHOTOHUB_NO_PHOTOS=1`.

## 6. First catalog build and scan

### Build the catalog

In the app: Settings → Archive → "Rebuild Catalog", or the Refresh button (Cmd+R). From Terminal:

```sh
scripts/rebuild_catalog.sh
```

This walks the archive without downloading anything (names, sizes, folders), reads the list of Photos items and albums, stacks versions, then computes trips, places, exact copies and people. Reading a large Photos library through Automation is the slow part and can take a few minutes. Your ratings, labels, tags, manual dates and "To Phone" marks are kept across rebuilds.

### Scan: previews and camera data

```sh
.venv/bin/photohub scan --dry-run          # what would be read, per folder, and how many GB
.venv/bin/photohub scan                    # everything
.venv/bin/photohub scan --root "2025"      # one folder
scripts/rebuild_catalog.sh                 # afterwards, to use the camera data
```

For each photo the scan downloads the file (if it is only in iCloud), reads the camera data with ExifTool, makes a 2048 px preview and a 640 px thumbnail, records a fingerprint and the SHA-256 hash (for exact copies), and returns the file to the cloud right away. RAW files that have a camera JPEG are skipped unless you pass `--all-raw`.

- **Time.** The speed is set by iCloud downloads: a few seconds per file for iCloud-only files, much faster for local ones. A large archive is a job for overnight; `scan` can be stopped with Ctrl-C and continues where it stopped.
- **Disk.** About 0.3 MB of previews and 45 KB of thumbnails per photo: around 6 GB for 18,000 photos. The scan stops when less than 8 GB is free.
- **The iCloud download cache.** Even though each file goes back to the cloud, macOS keeps a copy of what was downloaded in `~/Library/Caches/CloudKit/com.apple.bird/*/MMCS/ClonedFiles`. After a full scan of about 15,000 files it had grown to about 70 GB. Check it with `du -sh ~/Library/Caches/CloudKit/com.apple.bird/*/MMCS/ClonedFiles`. To free the space once the scan is finished and Finder shows no iCloud transfers in progress, quit PhotoHub and delete the contents of that folder: `rm -rf ~/Library/Caches/CloudKit/com.apple.bird/*/MMCS/ClonedFiles/*`. It is a cache; your files in iCloud Drive are not affected, and macOS also frees it on its own when the disk runs low.

The "Previews" toolbar button does a lighter version (thumbnails only) for the open folder.

## 7. Daily use

### The window

- **Sidebar:** Collections (the main screen), All Items, Map, Calendar, Folders, To Phone, Statistics; the gear at the bottom opens Settings.
- **Collections:** rows of On These Days in Past Years, Trips, Picks and Ratings, People, Pets, Events, Places, Cameras, Years, Photos albums, Types, Origin, To Sort Out, Where It Is Stored, My Tags, and Utilities with Hidden. "All ›" opens a row as a grid of cards.
- **Row order:** "Customize and Reorder" at the bottom of the Collections screen (also in the toolbar "…" menu and in Settings → Collections) lists the rows: drag a row to move it, uncheck it to hide it, "Restore Defaults" brings back the standard order. The choice is kept between launches; a row added in a later version appears at its default place.
- **Grid:** a tile is a shot with all its versions. Badges: Photos, Archive, RAW, ✎N (edits), stars, pick, phone; a color label is a strip and a dot. Click selects, Cmd-click adds, Shift-click selects a range; double click or Space opens the shot; right click opens the shot menu.
- **Filter bar:** sort, People (All, With Me, Without Me, one person), where it is stored, media, format, year, type, origin, camera, lens, RAW / Edits / Stacks (All, With, Without), label, rating, pick, More. "Only My Items" hides screenshots, messenger and saved images.
- **Shot page:** the versions in a strip at the bottom (↑ ↓ to switch), "Compare with Original", zoom, and on the right the dates, folder, tags, people, camera data and each file with "Show in Finder", "Open", "Open With…".
- **Statistics** (sidebar, Cmd+7, or "…" → Statistics): how many shots, files, photos, videos, RAW, edits, Live Photos, screenshots, saved images, version stacks and exact copies (with the space they waste) there are, and how many shots are only in the archive, only in Photos or in both; the size of the archive and of the Photos originals by type and by year, how much of the archive is downloaded on this Mac and how much is only in iCloud, the Photos library on disk, PhotoHub's own data and the iCloud download cache; shots per year and per month, the busiest day, the oldest shot, the longest trip, the most photographed place, countries, cities and trips, shots per travel day, the share of edits, top cameras, lenses, people, pets and places, ratings, picks and labels. Most tiles and rows open the matching shots. Sizes come from the catalog and from file attributes: nothing is downloaded to count them. Hidden shots are left out of every number, chart and highlight; while the Hidden collection is on, one "Hidden" tile shows how many there are. A summary is also in Settings → Statistics.
- **Navigation:** back and forward like a browser (‹ ›, Cmd+[ / Cmd+], mouse side buttons, a three-finger swipe if enabled). A shot opened from a collection returns to it.

### Keyboard shortcuts

| Keys | Where | What it does |
|---|---|---|
| Cmd+1 … Cmd+7 | everywhere except the shot page | Collections, All Items, Map, Calendar, Folders, To Phone, Statistics |
| Cmd+R | everywhere | refresh the catalog |
| Cmd+[ / Cmd+] | everywhere | back / forward |
| Cmd+Option+A | everywhere | agent panel |
| Cmd+Option+I | everywhere | show or hide the shot panel |
| Cmd+, | everywhere | settings |
| 1–5, 0 | grid and shot page | star rating, clear the rating |
| P, X, U | grid and shot page | pick, reject, clear the pick |
| T | grid and shot page | mark or unmark "To Phone" |
| Cmd+T | grid and shot page | tags, people and pets of the selected shots |
| 6, 7, 8, 9 | grid and shot page | red, yellow, green, blue label; the same key again removes it (purple is in the Label menu) |
| Cmd+Delete | grid | "Delete Everywhere…" for the selected shots |
| Cmd+Delete | shot page | the main version is open: "Delete Whole Shot…"; another version is open: "Delete This Version…", only that file |
| Cmd+L | grid and shot page | hide the selected shots, or unhide them if they are all hidden |
| Cmd+Z | grid and shot page | put back the archive files of the last delete; again for the delete before it (up to 20) |
| Space | grid / shot page | open the shot / back to the grid |
| ← → ↑ ↓ | grid | move the selection |
| ← → | shot page | previous / next shot |
| ↑ ↓ | shot page | versions of the shot |
| C, Z | shot page | compare with the original, fit / 100 % |
| Cmd+= Cmd+− Cmd+0 Cmd+1 | shot page | zoom in, zoom out, fit, 100 % |
| Esc | shot page | back |
| Cmd+= Cmd+− | calendar | zoom in and out: Year, Month, Week, Day (a trackpad pinch does the same) |
| ← → | calendar (Month, Week, Year) | previous / next month, week or year |

Rating, label and pick keys act on all selected shots and do nothing while you type in the search or agent field. They are stored in the catalog only, never in the files or in Lightroom.

### Hidden

Hiding is like the Hidden album in Photos: the files stay where they are, PhotoHub only stops showing them.

- **Hide shots:** select them and press Cmd+L, or right click → "Hide", or "Hide" in the shot panel. They leave All Items, years, On These Days, trips, places, the map, people, cameras, types, labels, search, every count and every cover.
- **Hide a folder:** right click a folder card (in Folders or in Events) → "Hide Folder…". Everything inside it, subfolders included, is hidden.
- **In a folder:** a line says how many of its items are hidden, and folder cards carry an eye badge with the number. "Show" asks for Touch ID or your password and shows them in place with an eye badge until you press "Hide Again" or leave the folder.
- **The Hidden collection:** Collections → Utilities → Hidden. It asks for Touch ID or the password, then shows the hidden folders as cards and one grid of all hidden shots, newest first, with the usual sort and filters.
- **Unhide:** select hidden shots and press Cmd+L or "Unhide"; for a folder, right click its card in Hidden → "Unhide Folder", or "Unhide Folder" inside it. A shot unhidden inside a hidden folder stays visible while the folder stays hidden.
- **Locking:** Hidden locks again when PhotoHub goes to the background, the screen sleeps, the window closes, or after 15 minutes.
- **Photos:** shots hidden in the Photos app count as hidden here too. The catalog build reads them from a copy of the Photos database (it needs Full Disk Access, like people and pets) and puts them only into Hidden; a shot whose Photos copy is hidden is hidden together with its archive files. When you hide a shot that is also in Photos, PhotoHub asks whether to hide it in Photos as well (so it is hidden on the phone) and can remember the answer; unhiding a shot that is hidden in Photos unhides it there too, after a one-time confirmation.
- **Settings → Hidden:** "Show Hidden collection" (off: no collection and no "N hidden" hints, hidden items stay hidden), "Use Touch ID or Password to view Hidden" (turning it off asks for the password), what to do with Photos copies, and "Open Hidden".
- Hidden marks are kept in the catalog by shot key and folder path and survive "Rebuild Catalog".

### Tags, people and pets

"Add Tag…" (Cmd+T, the shot menu, the item panel or the shot page) opens one picker for the selected shots. Type to search, or pick without typing:

- **On the shots** — the tags, people and pets already there. × removes one from all selected shots. A dashed chip is on only some of them ("2/5"); click it to add it to the rest.
- **People** and **Pets** — round avatars, cropped to the face or the animal when Vision finds one on the cover. Click toggles.
- **My Tags** — your own tags with the number of shots, the ones you used last first.
- **Create** — "Create Tag", "New Person" and "New Pet" with what you typed. When nothing matches, "Create Tag" is first and Return creates it.

Search ignores case and accents, matches the start of any word, finds Cyrillic names from a Latin spelling and the other way round ("masha" finds "Маша"), and forgives the wrong keyboard layout ("ьфнф" finds "Maya"). ↑ ↓ ← → move through the suggestions, Return adds or removes the highlighted one, Cmd+Z undoes the last change, Esc or Cmd+Return closes. Every change is saved at once; there is no OK button.

Tags, people and pets you set by hand are stored by the shot, not by the catalog row, so they survive a catalog rebuild. Removing a person that Photos recognized is remembered as "not this person" and wins over Photos on the next rebuild. Nothing is written to your files or to the Photos library.

### Calendar

Calendar in the sidebar (Cmd+4) shows what you shot on each day, like the archive calendar in Instagram. Day, Week, Month and Year switch with the control on the right, with Cmd+= and Cmd+− or with a pinch; ‹ › move by one period, "Today" returns to today, and a click on the title jumps to any month or year (years and months without shots are dimmed).

- **Month** (the default): months follow each other in one scroll, the newest at the bottom. A day with shots shows its cover photo with the day number and the number of shots; a day without shots shows only its number; today is ringed. Long runs of empty months fold into one line. A trip is a colored bar under its days; a click on the bar opens the trip. Hovering a day shows "12 shots · Kraków".
- **Year:** twelve small months with a tiny cover on each day with shots (a colored cell when the window is too small for pictures). A click on a month name opens that month, a click on a day opens the day. "N shots without an exact date" lists the year's shots whose day is not known.
- **Week:** seven columns with all shots of each day, the count and the place or trip.
- **Day:** the date, chips for the trip, places, people and pets of that day, and the usual grid: selection, the panel, the shot page and the keys work as everywhere; Back from a shot returns to the day, ‹ › go to the previous and next day with shots.

The cover of a day is chosen the same way every time: a favorite or the highest rating or a pick first, then an edit over the original, then the earliest shot; rejected shots come last. The calendar follows the filter bar, "Only My Items" and the search, uses dates set by hand, and leaves out shots without an exact date.

### Deleting

"Delete Everywhere…", "Delete Archive Copy…" and "Delete from Photos…" (Edit menu, shot menu, Cmd+Delete in the grid) act on whole shots with all their versions.

On the shot page what goes depends on the version that is open in the strip. With the main version open, Cmd+Delete is "Delete Whole Shot…": all its files. With another version open (a RAW, an edit, a Photos copy), Cmd+Delete is "Delete This Version…": only that file or Photos item; the shot stays with its other versions and the page shows the main version. If it was the last version, the shot disappears and the page moves to the next one. Both commands are in the Edit menu and in the delete button of the version panel; right-clicking a version in the strip offers "Delete This Version…". The question names what goes, for example "Delete RAW version “DSCF7170.RAF”?" or "Delete shot “DSCF7170” (2 files)?".

Every delete asks exactly once:

- **Photos items involved** (alone or together with archive files): the only question is the macOS window "Allow PhotoHub to delete …?". macOS always shows it for a Photos deletion and no app can skip it, so PhotoHub does not add its own; a notice at the bottom names what is being deleted while that window is open. All Photos items of the whole selection go into one request, so there is one window per action, however many shots are selected. Archive files of the same action go to the Trash only after you allow it there; if you cancel, nothing is deleted anywhere.
- **Archive files only**: PhotoHub shows one confirmation with the shots, how many files go to the Trash and from which folders, the sizes and what stays. Return confirms. With "Don't ask again" the files go to the Trash right away; turn the question back on in Settings → Archive → "Ask before moving archive files to the Trash".

After a delete a short notice at the bottom of the window says what went where, for example "Deleted 3 shots · 5 files moved to the Trash", and closes by itself. The selection moves to the next shot, and the shot page shows the next photo. "Undo" in the notice, or Cmd+Z (Edit → Undo Deletion), puts the archive files back where they were and returns them to the catalog. PhotoHub remembers the last 20 deletes of the session: each Cmd+Z puts back the one before, newest first. Photos items cannot be put back by an app: restore them in Photos → Recently Deleted ("Open Photos" in the notice); they stay there for 30 days. If something could not be deleted, the notice turns red and "Details" shows why.

"Delete Copies from Archive…" and "Delete from Photos, Keep in Archive…" in Photos Copies in Archive follow the same rules, except that deleting originals from Photos asks PhotoHub's own question first when some archive copies are smaller than the originals.

An archive file goes to the Trash. For an iCloud-only file macOS may refuse that without Full Disk Access; PhotoHub then moves it into iCloud Drive's own trash (`~/Library/Mobile Documents/.Trash`, shown as "Recently Deleted" in iCloud Drive), and as a last resort asks Finder. If everything fails, the message names the missing permission and offers to open the right settings pane. Undo finds the file where it actually went: the place macOS reported, or else the same file in the trash (also when Finder renamed it, as in "DSCF3119 2.RAF"), and recreates missing folders. iCloud Drive keeps syncing a deletion for a few seconds and can move a file that was put back too early to the trash again; PhotoHub watches for that and puts it back once more. Undo never replaces a file: if another file with the same name is in its place, the notice offers "Keep Both" (puts it back next to it under a new name). If the file cannot be put back, the red notice says exactly why and "Show in Trash" opens it in Finder; "Try Again" or Cmd+Z retries.

### Copies

- **Exact Copies in Archive** (To Sort Out) — byte-identical files in different places, found by the hash recorded during the scan. Only an identical file is a duplicate; edits and versions never are.
- **Photos Copies in Archive** — reduced copies dragged or exported out of Photos (names like `3E2EE545-…_1_105_c.jpeg`). Each becomes a version of its Photos shot; the collection shows both side by side with "Delete Copies from Archive…" and "Delete from Photos, Keep in Archive…".

### To Phone and Add to Archive

- **To Phone:** mark shots with T, open To Phone and press "Send to Photos". From each shot the edits go, or the JPEG if there is no edit; RAW files are not sent. The album is named after the event folder; items already in Photos are skipped.
- **Add to Archive…:** for a shot that exists only in Photos (shot page, the panel, or a selection). PhotoHub suggests up to four folders: events from the same days or trip, a folder with the city or dates in its name, `<me_folder>/<year>` if you are in the photo, the year folder. The original (HEIC, JPEG, RAW, Live Photo video) is written under its original name and its size is checked.

### People and pets

They come from the names you gave in the Photos app. On a catalog refresh PhotoHub reads a copy of `Photos.sqlite` (it needs Full Disk Access for that) and never changes the database. Merged people count as one; hidden shots, rejected faces and "Recently Deleted" are ignored. "With Me" and "Without Me" need to know who you are: Settings → People → "This is me" (by default the person in the most shots). To add a person or pet to a shot, or to take a wrong one off, use the tag picker (Cmd+T, see "Tags, people and pets" above); it works for archive shots that Photos never saw too.

### Settings

Open Settings with Cmd+, (PhotoHub menu → Settings…), the gear button at the bottom of the sidebar, or "Settings…" in the toolbar "…" menu.

| Tab | What it holds |
|---|---|
| General | the language (System, English or Russian; takes effect after a restart, "Restart Now" does it at once), the appearance (Follow System, Light, Dark; applies at once), the main shortcuts |
| Archive | the archive folder, "Rebuild Catalog" |
| Catalog | the data folder, the size of the catalog, thumbnails and previews, "Hide items that are not mine" |
| People | "This is me", the number of named people and pets |
| Collections | the order and visibility of the rows on the Collections screen, "Restore Defaults" |
| Hidden | "Show Hidden collection", Touch ID or password, what to do with Photos copies, "Open Hidden" |
| Statistics | the main numbers and sizes, "Open Statistics" for the charts |
| Agent | which `claude` program is used |

### What is not automatic yet

- The catalog does not watch the folders: press Refresh (Cmd+R) after changes.
- Previews exist only where you scanned or pressed "Previews".
- Edits are recognized by name, folder and EXIF; an edit with another name and no EXIF stays a separate shot.

## 8. Recognition: the analyzer and the face model

`PhotoHubAnalyzer` is a command-line tool in the same Swift package. It works offline from the previews the scan made (never from the originals) and from the Photos library's own thumbnails, and writes `vision.sqlite` next to the catalog.

```sh
swift build -c release --package-path App --product PhotoHubAnalyzer --scratch-path /tmp/photohub-analyzer-build
B=/tmp/photohub-analyzer-build/release/PhotoHubAnalyzer
$B run                       # Vision labels, fingerprints, faces and animals for all shots
$B search собака             # search by labels, English or Russian
$B similar 'a:2025/2025-06-12 Lisbon/DSCF0412_LR.jpg'
$B faces-embed               # SFace embeddings for the faces found by run
$B faces-label               # suggest names for unnamed faces, trained on the people named in Photos
$B stats
```

On an Apple M3, `run` handles 70–130 shots per second. The SFace face model (`App/Sources/PhotoHubAnalyzer/Resources/sface-fp16.mlpackage`, 18 MB, Apache 2.0) is already in the repository. `tools/faces/` has the scripts that downloaded and converted it (`fetch.sh`, `convert.py`); you only need them to reproduce the conversion or try another model. The methodology and the measured accuracy are in [docs/recognition.md](docs/recognition.md).

## 9. The agent

The sparkles button in the toolbar (Cmd+Option+A) opens a chat panel. It runs the [Claude Code](https://claude.com/claude-code) CLI from `~/.local/bin/claude` with your own login, in the project folder, and allows it only to run `.venv/bin/photohub` and read files. Its rules are in [AGENT.md](AGENT.md).

- Tags, ratings, picks and "To Phone" are applied at once.
- Moving files and changing dates always show a plan first and run only after you answer "yes"; the last move can be undone.
- It cannot delete anything.

Each message is a separate run and takes 10–30 seconds. Without Claude Code installed and logged in, the panel just reports that the agent could not start; the rest of the app is unaffected.

## 10. Troubleshooting

**"Catalog not found" on the first start.** Build it: Settings → Archive → "Rebuild Catalog", or `scripts/rebuild_catalog.sh`.

**"Catalog is updating…" does not go away (stale tags).** People, trips and places belong to one catalog build; when a rebuild was interrupted, the tags are from an older build and the app hides them. Run `.venv/bin/python -m photohub.tags`, or rebuild the catalog.

**No people and pets.** Grant Full Disk Access to PhotoHub (or to Terminal, if you rebuild from there), then refresh. Only people named in the Photos app are shown.

**macOS asks for Photos access after every build.** The app is signed ad-hoc. Set up a local signing identity (section 4) and keep the same `PHOTOHUB_BUNDLE_ID`.

**The app was moved to the Trash or "is damaged" right after building.** It was most likely signed with a revoked certificate. Delete or block that identity (`PHOTOHUB_BLOCKED_IDENTITIES`), sign with a self-signed local identity or ad-hoc, and rebuild.

**"Couldn't access your iCloud account" when deleting or scanning.** iCloud Drive's background service is signed out or stuck. Check System Settings → Apple Account → iCloud → iCloud Drive, wait for Finder to finish syncing, and try again; restarting the Mac resets the service.

**An external exFAT disk does not mount (macOS 15).** macOS 15 mounts exFAT through FSKit; after a disk was unplugged without ejecting, the mount can fail with "File exists" in the system log (`userfsd`). Restart the Mac, then mount the disk again. For an archive disk you use daily, APFS avoids this.

**Moves skip some files.** Files linked to a Lightroom Classic catalog are skipped on purpose, so Lightroom does not lose them.

## 11. Uninstall and clean up

1. Quit PhotoHub and delete `/Applications/PhotoHub.app`.
2. Delete the data folder `~/Library/Application Support/PhotoHub` (catalog, thumbnails, previews, `vision.sqlite`, settings). Your photos are not in it.
3. Remove the settings: `defaults delete <your bundle id>`.
4. Remove PhotoHub from System Settings → Privacy & Security (Photos, Full Disk Access, Automation), or reset them: `tccutil reset All <your bundle id>`.
5. Clear the iCloud download cache as described in section 6 if you ran a large scan.
6. The demo lives in `/tmp/photohub-demo`; delete the folder and run `defaults delete com.example.photohub.demo`.
