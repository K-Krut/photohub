# Development

How PhotoHub is put together, where it keeps its data, and how to check the UI without clicking through it. Installing and using the app is in [GUIDE.md](../GUIDE.md).

## Parts

| Part | Files |
|---|---|
| App (Swift, SwiftUI) | Swift package `App/`, sources `App/Sources/PhotoHub/*.swift`, built by `scripts/build_app.sh` |
| Paths and the no-Photos switch in the app | `App/Sources/PhotoHub/AppPaths.swift` |
| Catalog: shots, versions, albums | `backend/photohub/catalog.py` |
| Trips, places, exact copies, people and pets | `backend/photohub/tags.py` |
| Actions: tags, ratings, moves, dates, previews, scan, sending | `backend/photohub/cli.py`, the `.venv/bin/photohub` command |
| Paths: archive, data, hash index | `backend/photohub/config.py` |
| Recognition (Vision, SFace) | `App/Sources/PhotoHubAnalyzer`, see [recognition.md](recognition.md) |
| Agent rules | `AGENT.md` |
| Icon | `scripts/make_icon.py`, `App/Resources/AppIcon.icns` |
| Demo library and screenshots | `scripts/demo.sh`, `scripts/demo/`, `scripts/screenshots.sh` |

The app reads the catalog directly with SQLite and runs `.venv/bin/photohub` for everything that changes files or rebuilds the catalog. It finds the project through `project_path.txt` in the data folder, written by `scripts/build_app.sh`. The [roadmap](../ROADMAP.md) moves the backend into the app step by step.

## Data folder

`~/Library/Application Support/PhotoHub`, or `PHOTOHUB_SUPPORT`:

| File | What it holds |
|---|---|
| `catalog.sqlite` | the catalog. `item` (a shot; `key` is stable, `id` changes on every rebuild), `member` (its files), `album`, `tag` (trips, places, people, pets, origins, exact copies), `exact_copy`, `photos_hidden` (Photos items hidden in the Photos app), `meta` (`build_id`, `tags_build_id`). User data survives rebuilds: `mark` (rating, pick, color label), `user_tag`, `tag_override` (people and pets set by hand: `state` 1 adds, 0 removes an automatic one; the app merges it over `tag`), `flag` (To Phone), `date_override`, `main_choice`, `hidden_item` and `hidden_folder` (Hidden), `file_meta` (camera data from the scan) |
| `hash_index.sqlite` | `files` (SHA-256 per archive file) and `prints` |
| `thumbs/`, `previews/` | 640 px and 2048 px JPEGs, named by the SHA-1 of the archive path |
| `vision.sqlite` | the analyzer's labels, fingerprints, faces and embeddings |
| `config.json` | `archive_root`, `container_folders`, `me_folder` |
| `context.json` | what is open and selected, for the agent |
| `journal.jsonl` | the move log for `undo` |
| `project_path.txt` | where the project with `.venv` is |
| `demo_people.json` | optional, demo only: `{"people": {"Name": ["archive/path.jpg"]}, "pets": {...}}`, read by `tags.py` |

## Environment variables

| Variable | Used by | Meaning |
|---|---|---|
| `PHOTOHUB_SUPPORT` | app, backend, analyzer | the data folder |
| `PHOTOHUB_ARCHIVE` | app, backend | the archive folder, over `config.json` |
| `PHOTOHUB_CATALOG` | app, backend, analyzer | the catalog file |
| `PHOTOHUB_INDEX` | backend | the hash index |
| `PHOTOHUB_PHOTOS_LIBRARY` | backend, analyzer | the Photos library (default `~/Pictures/Photos Library.photoslibrary`) |
| `PHOTOHUB_NO_PHOTOS=1` | app, backend | ignore the Photos library: no JXA dump, no `Photos.sqlite`, no PhotoKit; trips come from file GPS |
| `PHOTOHUB_VISION`, `PHOTOHUB_MODELS` | analyzer | the vision database, extra model folders |
| `PHOTOHUB_SNAPSHOT`, `PHOTOHUB_SCOPES` | app | the self-snapshot mode below |
| `PHOTOHUB_APPEARANCE`, `PHOTOHUB_SNAPSHOT_SIZE` | app, snapshot mode | `light` or `dark`; the window content size, for example `1500x950` |
| `PHOTOHUB_HIDDEN_UNLOCKED=1` | app, snapshot mode only | treat Hidden as unlocked. Without it the snapshot mode keeps Hidden locked and never asks for Touch ID |

## Hidden

`App/Sources/PhotoHub/Hidden.swift`. A shot is hidden when its key is in `hidden_item` with `hidden = 1`, when its `root` is a folder in `hidden_folder` or under one and it has no `hidden = 0` row (a shot unhidden inside a hidden folder), or when its Photos asset is hidden in Photos: listed in `photos_hidden`, or reported by PhotoKit on reload. The Photos scripting dump leaves hidden items out, so `catalog.py` reads them (`ZASSET.ZHIDDEN = 1`, not trashed) from a copy of `Photos.sqlite`, adds them as Photos items and writes their ids to `photos_hidden`; `tags.py` keeps hidden shots out of trips and home detection, and people come only from shots that are not hidden. `Hidden.split` runs on every catalog load and is the only filter: it removes hidden shots from the item list and from every tag, album and flag set before the model builds grids, cards, covers, the folder tree, the map and counts. The Hidden collection (scope `.hidden`) and a folder shown with "Show" take their shots from `Hidden.source`. The Statistics page reads the catalog with its own SQL, so `HiddenShadow` (in `StatisticsData.swift`) puts the keys of the hidden shots into a temp table and shadows `item`, `member`, `tag` and `exact_copy` with temp views of the same names. The tag picker sees the tags of hidden shots through `Model.pickerSets` only, never as suggestions or avatars. The same rule in SQL is `HIDDEN` in `backend/photohub/catalog.py`, used by `photohub context`, `hide`, `unhide` and `phone`.

## Rebuilding the catalog

`scripts/rebuild_catalog.sh` is `python -m photohub.catalog`: shots, files and albums, then the tags in the same run. `--no-tags` leaves the `tag` table empty; until `python -m photohub.tags` computes the tags for this build, the app shows no people, pets, trips or places and says "Catalog is updating…". A build is marked by `build_id` and `tags_build_id` in `meta`, so tags of an older build are never shown on new item ids.

## Self-snapshot mode

The app can capture its own window to files, which is how the UI is checked and how the README screenshots are made. Snapshot windows are invisible and ignore clicks.

```sh
open -n -a /Applications/PhotoHub.app --env PHOTOHUB_SNAPSHOT=/tmp/shot --env "PHOTOHUB_SCOPES=home;folders:;root:2025/2025-06-12 Lisbon|select"
```

After a few seconds `/tmp/shot-0.png`, `/tmp/shot-1.png` and so on appear, and the second copy of the app quits. Next to each picture, `/tmp/shot-N.txt` has the title, the open shot, the selection and the back and forward history. Run it against a copy of the catalog (`--env PHOTOHUB_CATALOG=…`) or the demo when the steps change data.

A step is a section, then actions after `|`:

- Sections: `home`, `all`, `flagged`, `map`, `hidden`, `folders:path`, `root:path`, `list:key` (`trips`, `people`, `pets`, `places`, `events`, `years`, …), `year:2021`, `camera:name`, `tag:kind:name`, `card:key` (the first card of a row), `exports`, `photosonly`, `back`, `forward`, `settings:general|archive|catalog|people|collections|hidden|statistics|agent`, `stats` (the Statistics page), `menu:Item Title`, `calendar:<level>[:<date>]` (`month`, `week`, `year` or `day`, with an optional `2025-06`, `2025` or `2025-06-12`; `calendar:day` alone opens the latest day with shots). A step without a section stays where it is.
- Actions: `select`, `select3`, `selectN`, `stepN`, `view`, `page` (select the first shot and open it), `open` (the first subfolder), `back`, `forward`, `agent`, `reload`, `withme`, `withoutme`, `v2`, `compare`, `zoom`, `menus` (the menu bar with shortcuts to `<out>-menus.txt`), `vexport`, `selectphone`, `selectboth=N`, `addarchive`, `confirmcopies`, `confirmoriginals`, `close`.
- Labels, filters and sheets: `setlabel=red` (empty removes), `togglelabel=red`, `selectlabel=red`, `label=red|any|none`, `raw=` / `edits=` / `stacks=` with `with`, `without` or `all`, `sort=label` (a `SortKey` case), `reset`, `customize` (the row editor of the Collections screen), `statsspace`, `statsyears`, `statshighlights`, `statstop`, `statsmarks` (scroll the Statistics page), `rowtop=<row key>`, `rowhide=<row key>`, `rowsreset`, `delete=everywhere|archive|photos` (opens the confirmation only), `tagsheet` (the tag picker for the selection), `tagquery=text` (before `tagsheet`: typed into its search), `tagkeys=125,36` (key codes sent to the open picker: 123–126 arrows, 36 Return, 48 Tab, 53 Esc, 6 is Cmd+Z), `movesheet`, `closesheets`, `wide=2400`, `noinspector`, `labelstats`.
- Hidden: `reveal` (the open folder, only with `PHOTOHUB_HIDDEN_UNLOCKED=1`), `hideselected`, `unhideselected`, `hidefolder=path`, `unhidefolder=path` (these write to the catalog), `hiddenstats` (counts and a check that no hidden shot is a cover, appended to `<out>-hidden.txt`).
- An open sheet is captured to `<out>-N-sheet.png`.

Checks that touch files, for the real archive only when you mean it:

- `deletetest[:options]` creates `_photohub_delete_test-…txt` in the archive and deletes it with the code of the "Delete…" button. Options: `dataless`, `dir=<folder>`, `ext=`, `size=`, `each`, `only=coordinated+finder`, `askfinder`, `createonly`. The report goes to `<out>-deletetest.txt`.
- `exporttest` exports one Photos-only shot to `_photohub_test_export/` and reports sizes to `<out>-exporttest.txt`.
- `trashtest:path` sends an archive file or folder to the Trash and reports to `<out>-trashtest.txt`.

## Demo library and screenshots

`scripts/demo.sh` builds a self-contained demo in `/tmp/photohub-demo` (`PHOTOHUB_DEMO_DIR` to change it):

1. Downloads the photos listed in `scripts/demo/library.tsv` from Lorem Picsum (Unsplash photos, cached in `cache/`).
2. `scripts/demo/build_library.py build` writes the archive: camera names and EXIF (dates, cameras, lenses, GPS) through ExifTool, Lightroom-style edits and an export, exact copies, screenshots, messenger images, undated scans, `demo_people.json`, and `CREDITS.tsv`.
3. Builds the catalog with `PHOTOHUB_NO_PHOTOS=1`, runs `photohub scan`, rebuilds, and seeds ratings, labels, picks, tags and To Phone marks (`build_library.py seed`).
4. With `--analyze`, runs the analyzer on the demo.
5. Builds a separate app with the bundle id `com.example.photohub.demo`, signed ad-hoc, into the demo folder, sets its language to English, and opens it with the demo environment. `--no-launch` skips opening it.

The manifest columns are `id` (Picsum id), `folder`, `camera` (`fuji`, `sony`, `iphone`, `screenshot`, `none`), `day`, `place` (a key of `PLACES` in `build_library.py`) and `extras` (`edit`, `export`, `copy=<folder>`, `people=A+B`, `pet=Name`, `rate=N`, `pick`, `reject`, `label=color`, `phone`, `tag=Name`, `noexif`, `name=<file name>`, `caption=<text>`).

`scripts/screenshots.sh [out]` rebuilds the demo, runs the scenes listed at its top through the self-snapshot mode in the light appearance at 1500 × 950 (`PHOTOHUB_SCREENSHOT_APPEARANCE`, `PHOTOHUB_SCREENSHOT_SIZE`), and writes `docs/images/*.png` (at most 1600 px wide, compressed with `pngquant` when installed) and `docs/images/CREDITS.tsv`. Rerun it after UI changes.
