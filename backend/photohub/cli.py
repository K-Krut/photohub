import argparse
import calendar
import hashlib
import io
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unicodedata
from collections import Counter, defaultdict
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from datetime import datetime, timedelta
from pathlib import Path, PurePosixPath

from .catalog import COUNTER, HIDDEN, ensure_hidden, ensure_mark, event_root, open_index
from .config import ARCHIVE, CATALOG, INDEX, NO_PHOTOS, SUPPORT

LIGHTROOM = Path.home() / "Pictures/Lightroom/Lightroom Catalog.lrcat"
CONTEXT = SUPPORT / "context.json"
JOURNAL = SUPPORT / "journal.jsonl"
THUMBS = SUPPORT / "thumbs"
THUMB_SIDE = 640
DATALESS = 0x40000000
PILLOW_EXTENSIONS = {"jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp"}
SENDABLE = {"jpg", "jpeg", "png", "heic", "heif"}
PREVIEWS = SUPPORT / "previews"
PREVIEW_SIDE = 2048
RAW_EXTENSIONS = {"raf", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2"}
MIN_FREE = 8 * 1024**3
EXIFTOOL = shutil.which("exiftool") or "/opt/homebrew/bin/exiftool"
META_TAGS = ["DateTimeOriginal", "CreateDate", "Make", "Model", "LensModel", "Lens", "ISO", "FNumber", "ExposureTime", "FocalLength",
             "Software", "Composite:GPSLatitude", "Composite:GPSLongitude", "Composite:ImageSize", "Orientation"]
FILE_META = ("path", "size", "taken", "make", "model", "lens", "iso", "aperture", "shutter", "focal", "software", "lat", "lon",
             "width", "height", "dhash", "error", "scanned_at")
DELTA_UNIT = re.compile(r"(\d+)(min|y|m|d|h|s)")
DELTA_ARG = re.compile(r"-(?:\d+(?:min|y|m|d|h|s))+")
PLAN_LINES = 50


def catalog(readonly=False):
    if readonly:
        return sqlite3.connect(f"file:{CATALOG}?mode=ro", uri=True)
    db = sqlite3.connect(CATALOG, timeout=30)
    db.execute("CREATE TABLE IF NOT EXISTS flag (key TEXT PRIMARY KEY, phone INTEGER)")
    db.execute("CREATE TABLE IF NOT EXISTS user_tag (key TEXT, tag TEXT, PRIMARY KEY (key, tag))")
    db.execute("CREATE TABLE IF NOT EXISTS tag_override (key TEXT, kind TEXT, name TEXT, state INTEGER, PRIMARY KEY (key, kind, name))")
    ensure_mark(db)
    ensure_hidden(db)
    db.execute("CREATE TABLE IF NOT EXISTS date_override (key TEXT PRIMARY KEY, date TEXT, set_at TEXT)")
    return db


def context():
    return json.loads(CONTEXT.read_text()) if CONTEXT.exists() else {}


def target_keys(db, args):
    if args.items:
        ids = [int(x) for x in args.items.split(",") if x.strip()]
        rows = db.execute(f"SELECT key FROM item WHERE id IN ({','.join('?' * len(ids))})", ids).fetchall()
        return [r[0] for r in rows]
    if args.keys:
        return args.keys
    keys = [s["key"] for s in context().get("selected", [])]
    if not keys:
        sys.exit("Nothing is selected in the app. Select items or pass --items.")
    return keys


def hidden_counts(db):
    try:
        items = db.execute(f"SELECT COUNT(*) FROM item i WHERE {HIDDEN}").fetchone()[0]
        folders = [r[0] for r in db.execute("SELECT path FROM hidden_folder ORDER BY path")]
        marked = db.execute("SELECT COUNT(*) FROM hidden_item WHERE hidden = 1").fetchone()[0]
    except sqlite3.OperationalError:
        return {"items": 0, "marked": 0, "folders": []}
    return {"items": items, "marked": marked, "folders": folders}


def cmd_context(args):
    out = context()
    out["hidden"] = hidden_counts(catalog(readonly=True))
    print(json.dumps(out, ensure_ascii=False, indent=1))


def cmd_hide(args, hide=True):
    db = catalog()
    stamp = datetime.now().astimezone().isoformat(timespec="seconds")
    if args.folder is not None:
        folder = args.folder.strip("/")
        if not folder:
            sys.exit("Give a folder inside the archive, for example --folder \"Trips/2025-12 Vienna\".")
        if hide:
            db.execute("INSERT OR REPLACE INTO hidden_folder (path, set_at) VALUES (?, ?)", (folder, stamp))
            db.execute("DELETE FROM hidden_item WHERE hidden = 0 AND key IN (SELECT key FROM item WHERE in_archive = 1 "
                       "AND (root = ?1 OR substr(root, 1, length(?1) + 1) = ?1 || '/'))", (folder,))
        else:
            db.execute("DELETE FROM hidden_folder WHERE path = ?", (folder,))
        db.commit()
        n = db.execute("SELECT COUNT(*) FROM item WHERE in_archive = 1 AND (root = ?1 OR substr(root, 1, length(?1) + 1) = ?1 || '/')",
                       (folder,)).fetchone()[0]
        print(f"folder \"{folder}\" {'hidden' if hide else 'unhidden'}: {n} items inside")
        return
    keys = target_keys(db, args)
    if hide:
        db.executemany("INSERT OR REPLACE INTO hidden_item (key, hidden, set_at) VALUES (?, 1, ?)", [(k, stamp) for k in keys])
    else:
        in_folder = {r[0] for r in db.execute(f"SELECT i.key FROM item i WHERE i.key IN ({','.join('?' * len(keys))}) AND i.in_archive = 1 "
                                              "AND EXISTS (SELECT 1 FROM hidden_folder f WHERE i.root = f.path "
                                              "OR substr(i.root, 1, length(f.path) + 1) = f.path || '/')", keys)}
        db.executemany("INSERT OR REPLACE INTO hidden_item (key, hidden, set_at) VALUES (?, 0, ?)", [(k, stamp) for k in keys if k in in_folder])
        db.executemany("DELETE FROM hidden_item WHERE key = ?", [(k,) for k in keys if k not in in_folder])
    db.commit()
    print(f"{'hidden' if hide else 'unhidden'}: {len(keys)} items")


def cmd_unhide(args):
    cmd_hide(args, hide=False)


def cmd_sql(args):
    query = args.query.strip()
    if not query.lower().startswith(("select", "with")):
        sys.exit("Only SELECT queries are allowed.")
    db = catalog(readonly=True)
    cur = db.execute(query)
    print("\t".join(d[0] for d in cur.description))
    for n, row in enumerate(cur):
        if n >= args.limit:
            print(f"… showing the first {args.limit} rows")
            break
        print("\t".join("" if v is None else str(v) for v in row))


def cmd_tag(args):
    db = catalog()
    keys = target_keys(db, args)
    if args.kind == "user" and args.action == "add":
        db.executemany("INSERT OR IGNORE INTO user_tag VALUES (?, ?)", [(k, args.tag) for k in keys])
    elif args.kind == "user":
        db.executemany("DELETE FROM user_tag WHERE key = ? AND tag = ?", [(k, args.tag) for k in keys])
    elif args.action == "add":
        db.executemany("INSERT OR REPLACE INTO tag_override VALUES (?, ?, ?, 1)", [(k, args.kind, args.tag) for k in keys])
    else:
        rows = [(k, args.kind, args.tag) for k in keys]
        db.executemany("DELETE FROM tag_override WHERE key = ? AND kind = ? AND name = ?", rows)
        db.executemany("INSERT INTO tag_override SELECT ?1, ?2, ?3, 0 WHERE EXISTS (SELECT 1 FROM tag t JOIN item i ON i.id = t.item_id "
                       "WHERE i.key = ?1 AND t.kind = ?2 AND t.name = ?3)", rows)
    db.commit()
    label = args.tag if args.kind == "user" else f"{args.kind} {args.tag}"
    print(f"tag \"{label}\": {'added to' if args.action == 'add' else 'removed from'} {len(keys)} items")


def cmd_tags(args):
    for tag, n in catalog(readonly=True).execute("SELECT tag, COUNT(*) FROM user_tag GROUP BY tag ORDER BY 2 DESC"):
        print(f"{tag}\t{n}")


def cmd_flag(args):
    db = catalog()
    keys = target_keys(db, args)
    if args.action == "on":
        db.executemany("INSERT OR REPLACE INTO flag (key, phone) VALUES (?, 1)", [(k,) for k in keys])
    else:
        db.executemany("DELETE FROM flag WHERE key = ?", [(k,) for k in keys])
    db.commit()
    print(f"\"To phone\" {'on' if args.action == 'on' else 'off'} for {len(keys)} items")


def cmd_rate(args):
    db = catalog()
    keys = target_keys(db, args)
    for key in keys:
        db.execute("INSERT INTO mark (key, rating) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET rating = excluded.rating", (key, args.stars))
    db.commit()
    print(f"rating {args.stars}: {len(keys)} items")


def cmd_pick(args):
    value = {"on": 1, "reject": -1, "off": 0}[args.action]
    db = catalog()
    keys = target_keys(db, args)
    for key in keys:
        db.execute("INSERT INTO mark (key, pick) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET pick = excluded.pick", (key, value))
    db.commit()
    print(f"pick \"{args.action}\": {len(keys)} items")


def thumb_file(rel):
    return THUMBS / (hashlib.sha1(rel.encode("utf-8")).hexdigest() + ".jpg")


def make_thumb(src, dst):
    ext = src.suffix.lower().lstrip(".")
    if ext in PILLOW_EXTENSIONS:
        try:
            from PIL import Image, ImageOps
            from pillow_heif import register_heif_opener

            register_heif_opener()
            with Image.open(src) as im:
                im.draft("RGB", (THUMB_SIDE * 2, THUMB_SIDE * 2))
                im = ImageOps.exif_transpose(im).convert("RGB")
                im.thumbnail((THUMB_SIDE, THUMB_SIDE))
                im.save(dst, "JPEG", quality=82)
            return True
        except Exception:
            pass
    r = subprocess.run(["sips", "-Z", str(THUMB_SIDE), "-s", "format", "jpeg", "-s", "formatOptions", "80", str(src), "--out", str(dst)],
                       capture_output=True)
    return r.returncode == 0 and dst.exists()


def cmd_thumbs(args):
    THUMBS.mkdir(parents=True, exist_ok=True)
    db = catalog(readonly=True)
    where, params = ["in_archive = 1", "thumb_path != ''", "is_video = 0"], []
    if not args.all_sources:
        where.append("in_photos = 0")
    if args.root is not None:
        where.append("(root = ? OR root LIKE ? || '/%')")
        params += [args.root, args.root]
    if args.use_selected:
        keys = [s["key"] for s in context().get("selected", [])]
        where.append(f"key IN ({','.join('?' * len(keys))})")
        params += keys
    rows = db.execute(f"SELECT thumb_path FROM item WHERE {' AND '.join(where)} ORDER BY date DESC", params).fetchall()
    todo = [r[0] for r in rows if not thumb_file(r[0]).exists()]
    if args.limit:
        todo = todo[: args.limit]
    print(f"thumbnails: {len(todo)} of {len(rows)} to make", flush=True)
    made = failed = 0
    for n, rel in enumerate(todo, 1):
        src = ARCHIVE / rel
        try:
            cloud = bool(os.lstat(src).st_flags & DATALESS)
            ok = make_thumb(src, thumb_file(rel))
        except OSError:
            cloud, ok = False, False
        if cloud:
            subprocess.run(["brctl", "evict", str(src)], capture_output=True)
        made += ok
        failed += not ok
        if n % 10 == 0 or n == len(todo):
            print(f"thumbnails: {n}/{len(todo)}", flush=True)
    print(f"thumbnails done: made {made}, failed {failed}", flush=True)


def preview_file(rel):
    return PREVIEWS / (hashlib.sha1(rel.encode("utf-8")).hexdigest() + ".jpg")


def number(value, kind):
    try:
        return kind(value)
    except (TypeError, ValueError):
        return None


def exif_date(value):
    s = str(value or "")[:19]
    if not re.fullmatch(r"\d{4}:\d\d:\d\d \d\d:\d\d:\d\d", s) or s.startswith("0000"):
        return ""
    return f"{s[:4]}-{s[5:7]}-{s[8:]}"


def shutter_text(value):
    t = number(value, float)
    if not t or t <= 0:
        return ""
    return f"{t:g}" if t >= 0.3 else f"1/{round(1 / t)}"


def rounded(value):
    x = number(value, float)
    return None if x is None else round(x, 2)


def binary_size(value):
    m = re.search(r"Binary data (\d+) bytes", str(value or ""))
    return int(m[1]) if m else 0


def read_exif(src, raw):
    tags = META_TAGS + (["JpgFromRaw", "PreviewImage"] if raw else [])
    r = subprocess.run([EXIFTOOL, "-j", "-n", *[f"-{t}" for t in tags], str(src)], capture_output=True, encoding="utf-8", errors="replace", timeout=300)
    data = json.loads(r.stdout) if r.stdout.strip() else []
    if not data:
        raise RuntimeError(f"exiftool: {r.stderr.strip()[:100] or 'no data'}")
    return data[0]


def orient(im, orientation):
    from PIL import Image

    op = {2: Image.Transpose.FLIP_LEFT_RIGHT, 3: Image.Transpose.ROTATE_180, 4: Image.Transpose.FLIP_TOP_BOTTOM, 5: Image.Transpose.TRANSPOSE,
          6: Image.Transpose.ROTATE_270, 7: Image.Transpose.TRANSVERSE, 8: Image.Transpose.ROTATE_90}.get(orientation)
    return im.transpose(op) if op else im


def decode(src, ext, meta):
    from PIL import Image, ImageOps

    if ext in RAW_EXTENSIONS:
        sizes = {tag: binary_size(meta.get(tag)) for tag in ("JpgFromRaw", "PreviewImage")}
        for tag in sorted((t for t in sizes if sizes[t]), key=sizes.get, reverse=True):
            data = subprocess.run([EXIFTOOL, "-b", f"-{tag}", str(src)], capture_output=True, timeout=300).stdout
            try:
                im = Image.open(io.BytesIO(data))
                im.draft("RGB", (PREVIEW_SIDE, PREVIEW_SIDE))
                im.load()
            except Exception:
                continue
            if max(im.size) < THUMB_SIDE:
                continue
            if im.getexif().get(0x0112):
                im = ImageOps.exif_transpose(im)
            else:
                im = orient(im, number(meta.get("Orientation"), int))
            return im.convert("RGB"), tag
    elif ext in PILLOW_EXTENSIONS:
        try:
            with Image.open(src) as im:
                im.draft("RGB", (PREVIEW_SIDE, PREVIEW_SIDE))
                return ImageOps.exif_transpose(im).convert("RGB"), ""
        except Exception:
            pass
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "render.jpg"
        r = subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "95", str(src), "--out", str(out)], capture_output=True, timeout=600)
        if r.returncode != 0 or not out.exists():
            raise RuntimeError("sips could not open the file")
        with Image.open(out) as im:
            return ImageOps.exif_transpose(im).convert("RGB"), "sips"


def save_jpeg(im, side, dst, quality):
    from PIL import Image

    out = im.copy()
    out.thumbnail((side, side), Image.Resampling.LANCZOS)
    part = dst.with_name(dst.name + ".part")
    out.save(part, "JPEG", quality=quality)
    os.replace(part, dst)
    return out


def scan_file(rel, ext):
    from pillow_heif import register_heif_opener

    from .fingerprint import dhash

    register_heif_opener()
    src = ARCHIVE / rel
    row = {"taken": "", "make": "", "model": "", "lens": "", "software": "", "dhash": "", "error": "", "source": ""}
    try:
        st = os.lstat(src)
        cloud = bool(st.st_flags & DATALESS)
    except OSError:
        row["error"] = "file not found"
        return row
    row.update(mtime=st.st_mtime, dataless=int(cloud))
    try:
        meta = read_exif(src, ext in RAW_EXTENSIONS)
        orientation = number(meta.get("Orientation"), int)
        lens = meta.get("LensModel") or meta.get("Lens") or ""
        row.update(taken=exif_date(meta.get("DateTimeOriginal")) or exif_date(meta.get("CreateDate")),
                   make=str(meta.get("Make") or "").strip(), model=str(meta.get("Model") or "").strip(), lens=str(lens).strip(),
                   iso=number(meta.get("ISO"), int), aperture=rounded(meta.get("FNumber")), shutter=shutter_text(meta.get("ExposureTime")),
                   focal=rounded(meta.get("FocalLength")), software=str(meta.get("Software") or "").strip(),
                   lat=number(meta.get("GPSLatitude"), float), lon=number(meta.get("GPSLongitude"), float))
        size = [int(x) for x in re.findall(r"\d+", str(meta.get("ImageSize") or ""))]
        if len(size) == 2 and all(size):
            row["width"], row["height"] = (size[1], size[0]) if orientation in (5, 6, 7, 8) else size
        im, row["source"] = decode(src, ext, meta)
        if "width" not in row:
            row["width"], row["height"] = im.size
        row["dhash"] = dhash(im)
        row["sha256"] = file_sha256(src)
        preview = save_jpeg(im, PREVIEW_SIDE, preview_file(rel), 85)
        save_jpeg(preview, THUMB_SIDE, thumb_file(rel), 82)
    except Exception as e:
        row["error"] = f"{type(e).__name__}: {e}"[:200]
    finally:
        if cloud:
            evict(src)
    return row


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(8 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def evict(src):
    for attempt in range(3):
        if attempt:
            time.sleep(2)
        subprocess.run(["brctl", "evict", str(src)], capture_output=True)
        try:
            if os.lstat(src).st_flags & DATALESS:
                return
        except OSError:
            return


def scan_plan(db, args):
    where, params = ["m.source = 'archive'", "m.role IN ('photo', 'edit', 'raw')"], []
    if args.root is not None:
        where.append("(i.root = ? OR i.root LIKE ? || '/%')")
        params += [args.root, args.root]
    if not args.all_raw:
        where.append("(m.role != 'raw' OR NOT EXISTS (SELECT 1 FROM member o WHERE o.item_id = m.item_id AND o.source = 'archive' AND o.role = 'photo'))")
    rows = db.execute(f"SELECT m.path, m.size, m.ext, i.root FROM member m JOIN item i ON i.id = m.item_id WHERE {' AND '.join(where)} "
                      "ORDER BY i.date DESC, m.path", params).fetchall()
    has_meta = db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'file_meta'").fetchone()
    known = {p: (s, e) for p, s, e in db.execute("SELECT path, size, error FROM file_meta")} if has_meta else {}
    todo, seen, skipped = [], set(), 0
    for path, size, ext, root in rows:
        if path in seen:
            continue
        seen.add(path)
        prev = known.get(path)
        if prev and prev[0] == size and (prev[1] or (thumb_file(path).exists() and preview_file(path).exists())):
            skipped += 1
        else:
            todo.append((path, size, (ext or "").lower(), root or ""))
    return todo, skipped


def cmd_scan(args):
    db = catalog(readonly=args.dry_run)
    if not args.dry_run:
        db.execute("CREATE TABLE IF NOT EXISTS file_meta (path TEXT PRIMARY KEY, size INTEGER, taken TEXT, make TEXT, model TEXT, lens TEXT, "
                   "iso INTEGER, aperture REAL, shutter TEXT, focal REAL, software TEXT, lat REAL, lon REAL, width INTEGER, height INTEGER, "
                   "dhash TEXT, error TEXT, scanned_at TEXT)")
        db.commit()
    todo, skipped = scan_plan(db, args)
    if args.limit:
        todo = todo[: args.limit]
    total_bytes = sum(t[1] or 0 for t in todo)
    if args.dry_run:
        folders = {}
        for path, size, _, _ in todo:
            top = PurePosixPath(path).parts[0] if "/" in path else "."
            n, b = folders.get(top, (0, 0))
            folders[top] = (n + 1, b + (size or 0))
        print(f"scan (dry run): {len(todo)} files to scan, {total_bytes / 1e9:.1f} GB; already done {skipped}")
        for top, (n, b) in sorted(folders.items(), key=lambda kv: -kv[1][1]):
            print(f"   {top}\t{n} files\t{b / 1e9:.2f} GB")
        return
    if not shutil.which("exiftool") and not Path(EXIFTOOL).exists():
        sys.exit("exiftool not found. Install it: brew install exiftool")
    THUMBS.mkdir(parents=True, exist_ok=True)
    PREVIEWS.mkdir(parents=True, exist_ok=True)
    print(f"scan: {len(todo)} files to scan, {total_bytes / 1e9:.1f} GB; already done {skipped}", flush=True)
    index = open_index()
    done = errors = 0
    stopped = False
    pending = {}
    queue = iter(todo)
    with ThreadPoolExecutor(max(1, args.workers)) as pool:
        while True:
            while not stopped and len(pending) < max(1, args.workers):
                job = next(queue, None)
                if job is None:
                    break
                if shutil.disk_usage(Path.home()).free < MIN_FREE:
                    print("scan stopped: less than 8 GB of free disk space", flush=True)
                    stopped = True
                    break
                pending[pool.submit(scan_file, job[0], job[2])] = job
            if not pending:
                break
            finished, _ = wait(pending, return_when=FIRST_COMPLETED)
            for future in finished:
                path, size, _, root = pending.pop(future)
                try:
                    row = future.result()
                except Exception as e:
                    row = {"error": f"{type(e).__name__}: {e}"[:200]}
                row.update(path=path, size=size, scanned_at=time.strftime("%Y-%m-%d %H:%M:%S"))
                db.execute(f"INSERT OR REPLACE INTO file_meta ({', '.join(FILE_META)}) VALUES ({', '.join('?' * len(FILE_META))})",
                           [row.get(k) for k in FILE_META])
                db.commit()
                if row.get("sha256"):
                    index.execute("INSERT OR REPLACE INTO files (source, path, size, mtime, dataless, sha256) VALUES ('icloud', ?, ?, ?, ?, ?)",
                                  (path, size, row.get("mtime"), row.get("dataless"), row["sha256"]))
                    index.commit()
                done += 1
                errors += bool(row.get("error"))
                if done % 10 == 0:
                    print(f"scan: {done}/{len(todo)} · {root}", flush=True)
    print(f"scan done: processed {done}, errors {errors}, skipped {skipped}", flush=True)


def photo_library():
    from .catalog import DUMP_ITEMS, jxa

    if NO_PHOTOS:
        return set()
    return {(name.lower(), size) for _, name, _, size, *_ in jxa(DUMP_ITEMS)}


def cmd_phone(args):
    db = catalog()
    rows = db.execute(f"SELECT i.id, i.key, i.title, i.root FROM item i JOIN flag f ON f.key = i.key WHERE f.phone = 1 AND i.in_archive = 1 AND NOT {HIDDEN}").fetchall()
    library = photo_library()
    plan, skipped = {}, []
    for item_id, key, title, root in rows:
        members = db.execute("SELECT path, name, ext, size, role FROM member WHERE item_id = ? AND source = 'archive'", (item_id,)).fetchall()
        edits = [m for m in members if m[4] == "edit" and m[2] in SENDABLE]
        photos = [m for m in members if m[4] == "photo" and m[2] in SENDABLE]
        chosen = edits or photos
        if not chosen:
            skipped.append((title, "no JPEG/HEIC/PNG, only RAW or video"))
            continue
        album = PurePosixPath(root).name if root else "PhotoHub"
        for path, name, ext, size, role in chosen:
            if (name.lower(), size) in library:
                skipped.append((path, "already in Photos"))
            else:
                plan.setdefault(album, []).append(path)
    for album, paths in plan.items():
        print(f"album \"{album}\": {len(paths)}")
        for p in paths:
            print(f"   {p}")
    for what, why in skipped:
        print(f"SKIPPED {what}: {why}")
    total = sum(len(p) for p in plan.values())
    print(f"\nto send to Photos: {total} files, skipped: {len(skipped)}")
    if not args.apply:
        print("This is a plan. Nothing was sent. Run again with --apply to do it.")
        return
    if NO_PHOTOS:
        sys.exit("The Photos library is turned off (PHOTOHUB_NO_PHOTOS), nothing was sent.")
    from .catalog import jxa
    from .photos_import import JXA

    script = SUPPORT / "import_job.js"
    script.write_text(JXA)
    sent = 0
    for album, paths in plan.items():
        jxa(f"const P = Application('Photos'); if (!P.albums.whose({{name: {json.dumps(album)}}})().length) P.make({{new: 'album', named: {json.dumps(album)}}}); 'ok'".replace("'ok'", "JSON.stringify('ok')"))
        for start in range(0, len(paths), 20):
            batch = [str(ARCHIVE / p) for p in paths[start : start + 20]]
            for p in batch:
                with open(p, "rb") as f:
                    while f.read(8 * 1024 * 1024):
                        pass
            job = SUPPORT / "import_job.json"
            job.write_text(json.dumps({"album": album, "paths": batch, "extraAlbum": None, "extraPaths": []}))
            r = subprocess.run(["osascript", "-l", "JavaScript", str(script), str(job)], capture_output=True, text=True, timeout=1800)
            if r.returncode == 0:
                sent += len(batch)
            else:
                print(f"ERROR importing a batch: {r.stderr.strip()[:200]}")
            for p in batch:
                subprocess.run(["brctl", "evict", p], capture_output=True)
            print(f"sent: {sent}/{total}", flush=True)
    if not args.no_rebuild:
        rebuild()
    print(f"sent to Photos: {sent}")


def lightroom_paths():
    if not LIGHTROOM.exists():
        return set()
    try:
        cat = sqlite3.connect(f"file:{LIGHTROOM}?immutable=1", uri=True)
        rows = cat.execute("SELECT r.absolutePath, f.pathFromRoot, l.baseName, l.extension FROM AgLibraryFile l "
                           "JOIN AgLibraryFolder f ON l.folder = f.id_local JOIN AgLibraryRootFolder r ON f.rootFolder = r.id_local")
        return {unicodedata.normalize("NFC", os.path.normpath(f"{a}{b}{c}.{d}")).lower() for a, b, c, d in rows}
    except sqlite3.Error:
        return set()


def new_key(rel):
    parts = PurePosixPath(rel).parts
    root = event_root(list(parts[:-1]))
    m = COUNTER.match(parts[-1].rsplit(".", 1)[0])
    return f"a|{root}|{m[1].upper()}" if m else f"a|{rel}"


def update_index(pairs):
    if not INDEX.exists():
        return
    index = sqlite3.connect(INDEX, timeout=60)
    for old, new in pairs:
        index.execute("UPDATE files SET path = ? WHERE source = 'icloud' AND path = ?", (new, old))
        index.execute("UPDATE prints SET path = ? WHERE source = 'icloud' AND path = ?", (new, old))
    index.commit()


def rebuild():
    subprocess.run([sys.executable, "-m", "photohub.catalog"], check=True, stdout=subprocess.DEVNULL)


def cmd_move(args):
    to = unicodedata.normalize("NFC", args.to.strip().strip("/"))
    if not to or to.startswith("..") or "/../" in f"/{to}/":
        sys.exit("The destination folder must be inside the archive.")
    db = catalog()
    keys = target_keys(db, args)
    in_lightroom = set() if args.allow_lightroom else lightroom_paths()
    plan, skipped, key_map = [], [], {}
    lightroom = 0
    for key in keys:
        row = db.execute("SELECT id, root, title FROM item WHERE key = ?", (key,)).fetchone()
        if not row:
            skipped.append((key, "not in the catalog"))
            continue
        item_id, root, title = row
        members = [r[0] for r in db.execute("SELECT path FROM member WHERE item_id = ? AND source = 'archive'", (item_id,))]
        if not members:
            skipped.append((title, "the item is only in Photos, it has no files in the archive"))
            continue
        for rel in members:
            rest = rel[len(root) + 1 :] if root and rel.startswith(root + "/") else PurePosixPath(rel).name
            new = f"{to}/{rest}"
            src, dst = ARCHIVE / rel, ARCHIVE / new
            if new == rel:
                skipped.append((rel, "already in this folder"))
            elif not src.exists():
                skipped.append((rel, "file not found"))
            elif dst.exists():
                skipped.append((rel, "the destination folder already has a file with this name"))
            elif unicodedata.normalize("NFC", str(src)).lower() in in_lightroom:
                skipped.append((rel, "linked to the Lightroom catalog, move it inside Lightroom instead"))
                lightroom += 1
            else:
                plan.append((rel, new))
                key_map[key] = new_key(new)
    if args.json:
        print(json.dumps({"moves": [{"from": old, "to": new} for old, new in plan],
                          "skipped": [{"path": what, "reason": why} for what, why in skipped], "lightroom": lightroom}, ensure_ascii=False))
    else:
        for old, new in plan:
            print(f"{old}  →  {new}")
        for what, why in skipped:
            print(f"SKIPPED {what}: {why}")
        print(f"\nto move: {len(plan)} files, skipped: {len(skipped)}")
    if not args.apply:
        if not args.json:
            print("This is a plan. Nothing was moved. Run the command again with --apply to do it.")
        return
    done = []
    for old, new in plan:
        (ARCHIVE / new).parent.mkdir(parents=True, exist_ok=True)
        os.rename(ARCHIVE / old, ARCHIVE / new)
        done.append([old, new])
    with JOURNAL.open("a") as f:
        f.write(json.dumps({"time": time.strftime("%Y-%m-%d %H:%M:%S"), "moves": done, "keys": key_map}, ensure_ascii=False) + "\n")
    update_index(done)
    for old_key, fresh in key_map.items():
        if old_key != fresh:
            db.execute("UPDATE OR IGNORE flag SET key = ? WHERE key = ?", (fresh, old_key))
            db.execute("UPDATE OR IGNORE user_tag SET key = ? WHERE key = ?", (fresh, old_key))
            db.execute("UPDATE OR IGNORE tag_override SET key = ? WHERE key = ?", (fresh, old_key))
            db.execute("UPDATE OR IGNORE mark SET key = ? WHERE key = ?", (fresh, old_key))
            db.execute("UPDATE OR IGNORE hidden_item SET key = ? WHERE key = ?", (fresh, old_key))
    db.commit()
    db.close()
    if not args.no_rebuild:
        rebuild()
    if not args.json:
        print(f"moved: {len(done)}. To undo: photohub undo")


def cmd_undo(args):
    lines = JOURNAL.read_text().splitlines() if JOURNAL.exists() else []
    if not lines:
        sys.exit("The journal is empty, nothing to undo.")
    batch = json.loads(lines[-1])
    back = []
    for old, new in batch["moves"]:
        if (ARCHIVE / new).exists() and not (ARCHIVE / old).exists():
            (ARCHIVE / old).parent.mkdir(parents=True, exist_ok=True)
            os.rename(ARCHIVE / new, ARCHIVE / old)
            back.append([new, old])
        else:
            print(f"SKIPPED {new}: the file changed or its original place is taken")
    JOURNAL.write_text("".join(line + "\n" for line in lines[:-1]))
    update_index(back)
    db = catalog()
    for old_key, fresh in batch.get("keys", {}).items():
        if old_key != fresh:
            db.execute("UPDATE OR IGNORE flag SET key = ? WHERE key = ?", (old_key, fresh))
            db.execute("UPDATE OR IGNORE user_tag SET key = ? WHERE key = ?", (old_key, fresh))
            db.execute("UPDATE OR IGNORE tag_override SET key = ? WHERE key = ?", (old_key, fresh))
            db.execute("UPDATE OR IGNORE mark SET key = ? WHERE key = ?", (old_key, fresh))
            db.execute("UPDATE OR IGNORE hidden_item SET key = ? WHERE key = ?", (old_key, fresh))
    db.commit()
    db.close()
    if not args.no_rebuild:
        rebuild()
    print(f"moved back: {len(back)} files (move from {batch['time']})")


def parse_moment(text):
    s = (text or "").strip()
    if re.fullmatch(r"\d{4}-\d\d-\d\d \d\d:\d\d", s):
        s += ":00"
    try:
        if not re.fullmatch(r"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d", s):
            raise ValueError
        return datetime.strptime(s, "%Y-%m-%d %H:%M:%S").strftime("%Y-%m-%d %H:%M:%S")
    except ValueError:
        sys.exit(f"Cannot parse the date \"{text}\". Format: \"YYYY-MM-DD HH:MM\" or \"YYYY-MM-DD HH:MM:SS\".")


def parse_delta(text):
    s = (text or "").strip()
    body = s.lstrip("+-")
    units = DELTA_UNIT.findall(body)
    if not body or len(s) - len(body) > 1 or "".join(n + u for n, u in units) != body:
        sys.exit(f"Cannot parse the shift \"{text}\". Examples: +30d, -2h, +1m (month), +1y, +1m2d, +15min.")
    sign = -1 if s.startswith("-") else 1
    delta = Counter()
    for n, unit in units:
        delta[unit] += sign * int(n)
    return delta


def shift_moment(value, delta):
    t = datetime.fromisoformat(value[:19])
    months = t.month - 1 + delta["m"] + 12 * delta["y"]
    year, month = t.year + months // 12, months % 12 + 1
    t = t.replace(year=year, month=month, day=min(t.day, calendar.monthrange(year, month)[1]))
    t += timedelta(days=delta["d"], hours=delta["h"], minutes=delta["min"], seconds=delta["s"])
    return t.strftime("%Y-%m-%d %H:%M:%S")


def where_keys(expr):
    if ";" in expr or "--" in expr or "/*" in expr:
        sys.exit("--where must not contain \";\" or comments.")
    try:
        return [r[0] for r in catalog(readonly=True).execute(f"SELECT key FROM item WHERE ({expr}) ORDER BY date, key")]
    except sqlite3.Error as e:
        sys.exit(f"Error in --where: {e}")


def cmd_date(args):
    db = catalog()
    keys = list(dict.fromkeys(where_keys(args.where) if args.where else target_keys(db, args)))
    overrides = dict(db.execute("SELECT key, date FROM date_override"))
    if args.action == "set":
        moment = parse_moment(args.value)
    elif args.action == "shift":
        delta = parse_delta(args.value)
    changes, skipped = [], []
    for key in keys:
        row = db.execute("SELECT title, date FROM item WHERE key = ?", (key,)).fetchone()
        title, current = row if row else (key, "")
        current = overrides.get(key) or current
        if args.action == "reset":
            if key in overrides:
                changes.append((key, title, current, None))
            else:
                skipped.append((key, "the date was not set manually"))
            continue
        if not row:
            skipped.append((key, "not in the catalog"))
            continue
        if args.action == "set":
            new = moment
        elif not current:
            skipped.append((key, "the item has no date, nothing to shift"))
            continue
        else:
            try:
                new = shift_moment(current, delta)
            except (ValueError, OverflowError):
                skipped.append((key, "the date is out of range"))
                continue
        if new == current:
            skipped.append((key, "the date does not change"))
            continue
        changes.append((key, title, current, new))
    if args.json:
        print(json.dumps({"changes": [{"key": k, "title": t, "old": o, "new": n} for k, t, o, n in changes],
                          "skipped": [{"key": k, "reason": r} for k, r in skipped]}, ensure_ascii=False))
    else:
        for key, title, old, new in changes[:PLAN_LINES]:
            print(f"{title}: {old or '—'}  →  {new or 'automatic (after the rebuild)'}")
        if len(changes) > PLAN_LINES:
            print(f"… and {len(changes) - PLAN_LINES} more")
        for key, why in skipped[:PLAN_LINES]:
            print(f"SKIPPED {key}: {why}")
        if len(skipped) > PLAN_LINES:
            print(f"… and {len(skipped) - PLAN_LINES} more skipped")
        print(f"\ndate changes: {len(changes)} items, skipped: {len(skipped)}")
    if not args.apply:
        if not args.json:
            print("This is a plan. Nothing was changed. Run the command again with --apply to do it.")
        return
    if args.action == "reset":
        db.executemany("DELETE FROM date_override WHERE key = ?", [(k,) for k, *_ in changes])
    else:
        now = time.strftime("%Y-%m-%d %H:%M:%S")
        db.executemany("INSERT OR REPLACE INTO date_override (key, date, set_at) VALUES (?, ?, ?)", [(k, n, now) for k, _, _, n in changes])
    db.commit()
    db.close()
    if not args.no_rebuild:
        rebuild()
    if not args.json:
        done = "automatic date restored" if args.action == "reset" else "date changed"
        print(f"{done} in the catalog for {len(changes)} items, files untouched")


def cmd_copies(args):
    db = catalog(readonly=True)
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'exact_copy'").fetchone():
        sys.exit("There is no exact copy table yet. Rebuild the catalog: photohub rebuild")
    groups = defaultdict(list)
    for sha, path, size, key, in_photos in db.execute("SELECT sha256, path, size, item_key, in_photos FROM exact_copy ORDER BY path"):
        p = PurePosixPath(path)
        groups[sha].append({"path": path, "folder": "" if str(p.parent) == "." else str(p.parent), "name": p.name, "size": size,
                            "item_key": key, "in_photos": in_photos})
    out = [{"sha256": sha, "size": rows[0]["size"], "count": len(rows), "wasted": rows[0]["size"] * (len(rows) - 1), "paths": rows}
           for sha, rows in groups.items()]
    out.sort(key=lambda g: (-g["wasted"], g["sha256"]))
    totals = {"groups": len(out), "files": sum(g["count"] for g in out), "freeable": sum(g["wasted"] for g in out)}
    if args.json:
        print(json.dumps({"groups": out, "totals": totals}, ensure_ascii=False))
        return
    for g in out[:20]:
        print(f"{g['count']} × {g['size'] / 1e6:.1f} MB, redundant {g['wasted'] / 1e6:.1f} MB  ({g['sha256'][:12]})")
        for p in g["paths"]:
            print(f"   {p['folder'] or '(root)'}  /  {p['name']}" + ("  [in Photos]" if p["in_photos"] else ""))
    if len(out) > 20:
        print(f"… and {len(out) - 20} more groups")
    print(f"\ngroups: {totals['groups']}, files: {totals['files']}, "
          f"freed by keeping one file per group: {totals['freeable'] / 1e9:.2f} GB")


def cmd_folders(args):
    counts = Counter(str(PurePosixPath(p).parent) for (p,) in catalog(readonly=True).execute("SELECT path FROM member WHERE source = 'archive'"))
    out = []
    for dirpath, dirnames, _ in os.walk(ARCHIVE):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for d in dirnames:
            rel = os.path.relpath(os.path.join(dirpath, d), ARCHIVE)
            out.append({"path": rel, "members": counts.get(rel, 0)})
    out.sort(key=lambda f: f["path"])
    if args.json:
        print(json.dumps({"folders": out}, ensure_ascii=False))
        return
    for f in out:
        print(f"{f['path']}\t{f['members']}")


def cmd_rebuild(args):
    rebuild()
    print("catalog rebuilt")


def add_targets(p):
    p.add_argument("--items", help="comma-separated item ids (from the catalog)")
    p.add_argument("--keys", nargs="*", help="item keys")
    p.add_argument("--selected", action="store_true", help="items selected in the app (default)")


def main():
    ap = argparse.ArgumentParser(description="Manage the PhotoHub catalog.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("context").set_defaults(func=cmd_context)
    p = sub.add_parser("sql")
    p.add_argument("query")
    p.add_argument("--limit", type=int, default=200)
    p.set_defaults(func=cmd_sql)
    p = sub.add_parser("tag")
    p.add_argument("action", choices=["add", "remove"])
    p.add_argument("tag")
    p.add_argument("--kind", choices=["user", "person", "pet"], default="user",
                   help="person and pet tags are stored as manual overrides of the Photos people")
    add_targets(p)
    p.set_defaults(func=cmd_tag)
    sub.add_parser("tags").set_defaults(func=cmd_tags)
    for name, func in (("hide", cmd_hide), ("unhide", cmd_unhide)):
        p = sub.add_parser(name)
        p.add_argument("--folder", help="an archive folder with everything inside it, for example 'Trips/2025-12 Vienna'")
        add_targets(p)
        p.set_defaults(func=func)
    p = sub.add_parser("flag")
    p.add_argument("action", choices=["on", "off"])
    add_targets(p)
    p.set_defaults(func=cmd_flag)
    p = sub.add_parser("move")
    p.add_argument("--to", required=True, help="folder inside the archive, for example 'Trips/2025-12 Vienna'")
    p.add_argument("--apply", action="store_true")
    p.add_argument("--allow-lightroom", action="store_true")
    p.add_argument("--no-rebuild", action="store_true")
    p.add_argument("--json", action="store_true")
    add_targets(p)
    p.set_defaults(func=cmd_move)
    p = sub.add_parser("date")
    p.add_argument("action", choices=["set", "shift", "reset"])
    p.add_argument("value", nargs="?", help="for set: \"YYYY-MM-DD HH:MM[:SS]\"; for shift: +30d, -2h, +1m, +1y, +1m2d")
    p.add_argument("--where", help="SQL condition on the item table, for example \"camera = 'FUJIFILM X10' AND date LIKE '2021-%%'\"")
    p.add_argument("--apply", action="store_true")
    p.add_argument("--no-rebuild", action="store_true")
    p.add_argument("--json", action="store_true")
    add_targets(p)
    p.set_defaults(func=cmd_date)
    p = sub.add_parser("copies")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_copies)
    p = sub.add_parser("folders")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_folders)
    p = sub.add_parser("undo")
    p.add_argument("--no-rebuild", action="store_true")
    p.set_defaults(func=cmd_undo)
    sub.add_parser("rebuild").set_defaults(func=cmd_rebuild)
    p = sub.add_parser("rate")
    p.add_argument("stars", type=int, choices=range(0, 6))
    add_targets(p)
    p.set_defaults(func=cmd_rate)
    p = sub.add_parser("pick")
    p.add_argument("action", choices=["on", "reject", "off"])
    add_targets(p)
    p.set_defaults(func=cmd_pick)
    p = sub.add_parser("thumbs")
    p.add_argument("--root", help="event folder in the archive (with its subfolders)")
    p.add_argument("--use-selected", action="store_true")
    p.add_argument("--all-sources", action="store_true", help="also for items that are in Photos")
    p.add_argument("--limit", type=int)
    p.set_defaults(func=cmd_thumbs)
    p = sub.add_parser("scan")
    p.add_argument("--root", help="event folder in the archive (with its subfolders)")
    p.add_argument("--limit", type=int)
    p.add_argument("--workers", type=int, default=3)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--all-raw", action="store_true", help="also RAW files that have a camera JPEG/HEIC")
    p.set_defaults(func=cmd_scan)
    p = sub.add_parser("phone")
    p.add_argument("--apply", action="store_true")
    p.add_argument("--no-rebuild", action="store_true")
    p.set_defaults(func=cmd_phone)
    args = ap.parse_args([" " + a if DELTA_ARG.fullmatch(a) else a for a in sys.argv[1:]])
    args.func(args)


if __name__ == "__main__":
    main()
