# PhotoHub plan

The goal is a full macOS app: it installs into `/Applications`, launches like any other app, permissions are granted once, settings live inside the app, and the catalog updates by itself. While running, the app does not depend on the project folder, `.venv`, Python scripts or AppleScript.

Principles:

- A duplicate is only a byte-identical file. All versions and edits of a shot are kept.
- Archive files live in iCloud and are not downloaded without need. Analysis and previews work from previews that already exist.
- Nothing is deleted without an explicit confirmation. Deleted items go to the Trash or to "Recently Deleted".
- Each finished change is a separate commit. The owner pushes to GitHub.

## Step 1. A proper app

- Signing with an Apple developer certificate, so that access to Photos and Full Disk Access are not lost after a rebuild.
- Installation into `/Applications`, version and build number, icon, a correct `Info.plist`.
- A "Settings" window: archive folder, data folder, auto-update, agent.
- App menu: "Refresh Catalog", "Make Previews", "Send to Photos", navigation between sections.
- Navigation: a single "back" arrow goes to the previous screen, a photo opened from a collection returns to the collection; "forward"; Esc and Cmd+[ / Cmd+].

## Step 2. Catalog in Swift

- Walking the archive with FileManager without downloading files.
- The Photos library through PhotoKit instead of AppleScript: shots, albums, locations, types, hidden items.
- Stacks, version roles, origin, cameras, dates (EXIF, name, Photos, file date, folder, manual), trips, places, exact copies.
- Copies from Photos in the archive (`<UUID>_N_NNN_x.jpeg`): attaching them to the Photos shot with the same UUID with the role `export`. Today this is `attach_exports` in `backend/photohub/catalog.py` and the "own archive" condition in `tags.py` — move it to Swift. Deleting copies and "Add to Archive" are already in Swift.
- The city gazetteer as a resource inside the app.
- People and pets from the Photos database: today this is `read_people` and `photos_people` in `backend/photohub/tags.py` (a copy of `Photos.sqlite`, merged people, hidden and rejected faces). Move it to Swift; PhotoKit does not give out people's names, so reading a copy of the database stays, and PhotoHub needs "Full Disk Access".
- Check: the Swift catalog matches the Python reference in the numbers of shots, files, stacks, tags and copies.

## Step 3. Scanning and actions in Swift

- Previews and camera data through ImageIO, including RAW and HEIC; a dHash fingerprint; SHA-256 through CryptoKit.
- Returning files to the cloud through FileManager, clearing the iCloud download cache after large passes.
- Actions: moving (plan, confirmation, undo), manual dates and shifts, deleting a shot everywhere, exact copies.
- Sending to Photos through PhotoKit (PHAssetCreationRequest) instead of AppleScript.
- Auto-update: watching the archive folder (FSEvents) and the Photos library (PHPhotoLibraryChangeObserver); new files are scanned in the background.

## Step 4. Agent without Python

- A command-line tool inside the app (`PhotoHub.app/Contents/MacOS/photohub`) with the same commands the Python one has now.
- The built-in agent works through it. The agent is an external Claude Code on the owner's subscription, on the Opus 5.5 model.
- The `backend/` folder is deleted.

## Step 5. Features

Next up, in this order:

1. Color labels like Lightroom (6 red, 7 yellow, 8 green, 9 blue, purple from the menu), label filter and sort, "Select all with this label"; a right-click menu on tiles acting on the whole selection (delete everywhere / archive copy only / Photos copy only with one confirmation, label, rating, pick, tags, send to Photos, add to archive, move, open in…, Cmd+Backspace); three-state filters RAW / Edits / Stacks (All / With / Without).
2. Safety net: Cmd+Z undo for deletions and other actions; a "Recently Deleted" section that lists the iCloud Drive trash and Photos' Recently Deleted with "Restore"; drag and drop of files from Finder into PhotoHub, asking where to add them (an archive folder with suggestions and/or Photos).
3. Cards like in Photos: real previews on folder and collection cards (a key photo; a 2×2 mosaic of covers for folders with subfolders), using cached archive thumbnails. A folder that has subfolders shows its subfolder cards on top and, below them, one grid of ALL shots inside it recursively (default order: by date, newest first; the usual sort and filters apply), so nobody has to open every subfolder to see the photos.
4. Versions made clear: an identical file present in both the archive and Photos is one version with location badges ("archive", "Photos", "both") instead of two cards; "where it lives" on tiles, version cards and the panel.
5. "Already on the phone": for shots that already have a copy in Photos the "Send to Photos" switch shows as on and disabled; a separate "Send this version to Photos" appears only when a different version (e.g. an edit) is not in Photos yet.
6. A glass-style refresh: translucent sidebar and toolbar, material cards and floating controls, bigger previews, fewer borders, soft shadows and animations (system materials on macOS 15; real Liquid Glass when built for macOS 26).
7. Blurry and failed shots: sharpness (measured on faces when present), exposure, closed eyes, worst-in-burst, computed from cached previews; a "Failed shots" set, a quality filter, review and bulk delete with confirmation, "This shot is fine" to dismiss.
8. Import from devices:
   - when an SSD, a flash drive or a camera card is connected, PhotoHub lists it under "Devices" in the sidebar and scans it read-only: previews, EXIF, SHA-256;
   - it shows what is new compared with the archive and Photos; exact duplicates are found by hash;
   - known people are recognized; unknown faces are grouped into "Who is this?" for naming. Naming groups of unknown faces is a general feature for the whole archive too;
   - an import wizard: a destination plan by year and event rules, copy or move between volumes with hash verification, previews made during the import;
   - per volume the user can switch from read-only to "Manage this drive": an explicit write permission, remembered by the volume UUID. Then PhotoHub can move, rename and delete (to that volume's Trash), organize the drive and move files between volumes — always through a plan and a confirmation.

Then:

- Calendar — done: Day, Week, Month and Year like Apple Calendar, Instagram-style day covers in the month view, trips as bars across their days, zoom with Cmd+= / Cmd+− or a pinch, quick jump to a month or year; follows the filters and manual dates.
- "Hidden" — done: hide shots (⌘L, the shot menu, the panel) and folders (the menu of a folder card), stored by item key and folder path so it survives rebuilds; hidden items leave every view, count and cover; a folder shows "N hidden" and shows them in place after Touch ID or the password; the "Hidden" collection under Collections → Utilities lists hidden folders and all hidden shots; it locks when the app goes to the background, the screen sleeps or after 15 minutes; shots hidden in Photos count as hidden, and hiding or unhiding a shot with a Photos copy can do the same in Photos through PhotoKit; `photohub hide` / `unhide` for the agent. Still open:
  - hiding and unhiding in Photos through PhotoKit is untested on a real library (the catalog build reads hidden Photos items from a copy of `Photos.sqlite`, because the Photos scripting dump leaves them out, and they land only in Hidden);
  - the shot panel and the People / Type filters inside Hidden do not know the trips, people, tags and Photos types of hidden shots, because those sets are stripped of hidden items;
  - shots hidden or unhidden in Photos while PhotoHub is open are picked up on the next catalog reload, not live.
- People and pets from Photos, the "People" and "Pets" rows, the "with me / without me" filter — done in Python, the port is in step 2.
- Buttons: "Move to…", "Change Date" and "Shift Date", "Delete Shot Everywhere".
- An exact-copies screen: copies side by side, where each one lives, choosing what to keep.
- Shifting the clock of one camera for a range of shots (a camera that was set to the wrong date), at the user's decision.
- Favorites (heart):
  - a heart on the tile, on the photo page and in the shot panel if the shot is a favorite in Photos or marked in PhotoHub;
  - set or clear the heart in PhotoHub (a button and a key). If the shot has a copy in Photos, the favorite is set there too (through PhotoKit), so the heart is also on the phone; for archive-only shots it is stored in the catalog;
  - the "Favorites" collection and filter combine both sources.
- The filter bar wraps onto a second line instead of scrolling horizontally, so all filters are visible at once.
- Cameras and lenses:
  - in the filter and in the "Cameras" row, "My cameras" come first (many of the owner's own shots), with a collapsed "Others" below — cameras of other people's photos, exports and one-off shots (Canon R6, 5D Mark III, Sony A7R III/IV, Redmi, Meizu, Lumia and so on);
  - in the settings a camera can be marked "mine" or "not mine", and the mark overrides the automatic choice;
  - iPhone lenses — short and human ("iPhone 14 Pro · main", "· ultra wide", "· front"), the lens list only for the chosen camera.
- Done: statistics: a Statistics page (sidebar) and a summary in Settings — counts by type and storage, exact copies and the space they waste, archive and Photos sizes by type and year, downloaded versus iCloud-only, PhotoHub's own data, shots per year and month, top cameras, lenses, people, pets and places, trips, ratings and labels.
- Done: row order on the main screen, as in Photos on the iPhone: "Customize and Reorder" on the Collections screen and in Settings → Collections, rows (Trips, People, Pets, Events and shoots, Places, Years, Types and so on) can be dragged with the mouse, any row can be hidden and brought back. Order and visibility persist between launches; "Restore Defaults" resets the setting.
- Collection covers:
  - "Make Cover" on any shot for any collection: person, pet, trip, place, folder, album, own tag, year, camera. The choice is stored by the shot key and survives a catalog rebuild;
  - by default the cover is chosen deterministically, not at random (for people — the shot with their face with the best rating, or the newest one), and does not change between launches or after a catalog update;
  - covers do not flicker or redraw on auto-update: the image cache survives a catalog reload.
- Manual tag editing in the app:
  - done: one tag picker (⌘T, "Add Tag…" in the shot menu, the item panel and the shot page) for one shot or a selection. People and pets as round avatars (a face or animal crop found by Vision on the cover, or the cover itself), own tags with usage counts, recent first; search ignores case and accents, matches word starts, Cyrillic and Latin spellings and the wrong keyboard layout; "Create Tag", "New Person" and "New Pet" for a new name; chips of the tags already on the shots with × (dashed when only some of the selection has them, a click adds to all); arrows, Return, ⌘Z inside the picker, Esc. Changes apply at once without reloading the catalog;
  - done: people and pets set by hand are stored by the shot key in `tag_override` and survive a catalog rebuild; removing a person or pet that came from Photos is stored as "not this person" and wins over the automatic result. `photohub tag add|remove --kind person|pet` does the same from the command line;
  - a list of all own tags: rename, merge two tags into one, delete a tag entirely;
  - correct the other automatic results: remove a wrong place, trip, origin or category from a shot, or add your own (`tag_override` already has a `kind` column for it). Events are folders and change by moving files;
  - avatars skip hidden shots once "Hidden" exists; ⌘Z for tag changes after the picker is closed, together with the app-wide undo.
- "Drawings and paintings": a separate set for saved paintings, drawings and illustrations, by Vision labels (painting, drawing, illustrations, art) with a threshold and a check on a sample. Separate from photos of paintings the owner took herself (museums, exhibitions) and from her own works (the "Painting" album).
- "Remove from the main feed" is not the same as "Hidden": no Touch ID, it simply does not show items in "All Items", years, "On this day", trips and places. A shot, a folder or a whole category (drawings, screenshots, saved images, messengers) can be removed. The list of removed items is in the settings, and each comes back with one click. The existing "Only My Items" switch becomes part of this mechanism.
- "Find Similar" on the photo page, like Pinterest. Example: `IMG_5996` from `2024-09-24` is open, and somewhere in the archive there is its edit with a different name in a different folder.
  - Search across the whole archive and Photos; results in a grid, sorted by similarity, each showing the similarity percentage, the folder and the date.
  - Result filters: only edits, only from other folders, only from Photos, similarity threshold.
  - Actions on the results: "This is an edit of this shot" (attach to the stack), "Detach", "Move to this shot's folder" (through a move plan with confirmation), "Open".
  - Manual links are stored separately from the automatic results and are not lost on a catalog rebuild. The automatic results do not overwrite them.
  - The first version uses the dHash fingerprint (scanned archive files already have it). It gets more accurate with the Vision fingerprints from step 6: they find edits with cropping and strong colour correction.
- A website: a landing page for PhotoHub.
  - Apple-style product page, dark theme first with a light one second; it shows off the glass interface with the screenshots from `docs/images` (dark and light), a short "why", the features (collections, folders, stacks of versions, trips and the map, people, labels, exact copies and safe deletion, the calendar, recognition, the agent), a privacy section (everything stays on the Mac, nothing is uploaded) and "Get PhotoHub": build from source with `scripts/install.sh`, plus a download once there is a release.
  - English first; Russian as a second page later.
  - Static HTML and CSS in its own `site/` folder, no framework and no trackers; it is never bundled into the app. Deployed with GitHub Pages from a workflow that publishes `site/` only.

## Step 6. Recognition and search

There is no need to train a model from scratch. Three layers, all running on the Mac, offline, from previews:

1. **Vision (built into macOS, takes no space).** Scenes and objects (about 1,300 categories: dog, cat, sea, food, document), faces, people, animals, an image fingerprint for "similar". The results are saved to the catalog.
2. **Text search.** A small ready-made model (for example MobileCLIP, on the order of tens of megabytes) in Core ML format: the query "dog on the beach" finds shots without tags. Queries in Russian and English.
3. **Own model.** Classifiers weighing kilobytes on top of face and animal fingerprints, trained on the people and pet tags from Photos. They recognise your people and cats in the archive, where there are no tags. They keep learning when you confirm or correct them.

Features on top: a search bar ("dog", "sea 2021", "Alex in Vienna"), "Find Similar" on Vision fingerprints (replacing the dHash from step 5), suggestions "this looks like an edit of this shot" confirmed with one click, collapsing bursts of nearly identical shots, tag suggestions, "This is her" and "This is not him" buttons.

## Order

1. Step 1 together with navigation.
2. Steps 2–4.
3. Step 5.
4. Step 6. Collecting data for it (Vision on previews) can start right after step 3.
