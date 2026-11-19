import argparse
import json
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
import unicodedata
import uuid
from collections import Counter, defaultdict
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path, PurePosixPath

from .config import ARCHIVE, CATALOG, INDEX, NO_PHOTOS, PHOTOS_LIBRARY, container_folders


RAW = {"raf", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2"}
VIDEO = {"mp4", "mov", "m4v", "wmv", "avi", "3gp", "mkv"}
IMAGE = {"jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp", "psd"}
CONTAINERS = set(container_folders())
YEAR = re.compile(r"(19|20)\d{2}")
COUNTER = re.compile(r"^(?:\d{8}-)?((?:DSCF|DSC_|DSC|IMG_E|IMG_|ZG5A|MVI_)\d{4,5})(?!\d)", re.I)
EDIT_MARK = re.compile(r"(?i)(?:^|[-_ ])(?:lr|ps|edit\w*|enhanced|\u0440\u0435\u0434\u0430\u043a\u0442\w*\.?)(?=$|[-_ .(\d])")
EDIT_DIR = re.compile(r"(?i)(\u044d\u043a\u0441\u043f\u043e\u0440\u0442|export|edited|^ps$)")
NAME_TS = re.compile(r"(?<!\d)(20\d{2})[-_.]?(\d{2})[-_.]?(\d{2})[ _-]?(\d{2})[-_.]?(\d{2})[-_.]?(\d{2})(?!\d{4})")
DIR_DATE = re.compile(r"^(20\d{2})-(\d{2})(?:-(\d{2}))?")
EDITOR = re.compile(r"(?i)lightroom|photoshop|camera raw|capture one|snapseed|vsco|picsart|affinity|pixelmator|luminar|darkroom|gimp"
                    r"|photo editor|acd systems|acdsee|facetune|polarr|afterlight|lightx|meitu|photoscape|paint\.net|canva")
GENERATOR = re.compile(r"(?i)midjourney|dall[-·]?e|stable diffusion|firefly|krea|leonardo|ideogram|novelai|comfyui|automatic1111|openai|chatgpt")
PHOTOS_EXPORT = re.compile(r"(?i)^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})_\d+_\d+_[a-z](?: \d+)?\.")
PHONE_NAME = re.compile(r"(?i)^IMG_E?\d{4}\.")
SCREEN_NAME = re.compile(r"(?i)^(screenshot|\u0441\u043d\u0438\u043c\u043e\u043a \u044d\u043a\u0440\u0430\u043d\u0430|\u0437\u043d\u0456\u043c\u043e\u043a \u0435\u043a\u0440\u0430\u043d\u0430)")
MESSENGER = re.compile(r"(?i)^(photo_\d{4}-\d{2}-\d{2}_|video_\d{4}-\d{2}-\d{2}|IMG-\d{8}-WA|IMG-[0-9a-f]{32}-V|signal-|telegram-)")
CAMERA_NAME = re.compile(r"(?i)^(?:DSCF\d{4}|DSC_?\d{4,5}|_DSC\d{4}|MVI_\d{4}|20\d{6}_\d{6})(?!\d)")
PHONE_STEM = re.compile(r"(?i)^IMG_\d{4}(?: \d+| ?\(\d+\))?$")
PHONE_PIXELS = 8_000_000
VIDEO_SHOT = re.compile(r"(?i)^(?:DSCF\d{4}|DSC_?\d{4,5}|MVI_\d{4}|IMG_E?\d{4}|20\d{6}_\d{6}|C\d{4})(?!\d)")
VIDEO_MESSENGER = re.compile(r"(?i)^(?:video_20\d{2}-\d{2}-\d{2}|VID-\d{8}-WA)")
VIDEO_SCREEN = re.compile(r"(?i)^(?:RPReplay|\u0437\u0430\u043f\u0438\u0441\u044c \u044d\u043a\u0440\u0430\u043d\u0430|screen recording)")
MAKES = {"apple": "", "samsung": "Samsung", "sony": "Sony", "fujifilm": "FUJIFILM", "canon": "Canon", "xiaomi": "Xiaomi", "nokia": "Nokia",
         "meizu": "Meizu"}
SAME_FRAME = 12
FILE_ORIGINS = {"screenshot", "messenger", "saved", "generated", "unknown"}
COPY_SHARE = 0.8
COPY_MIN = 20
COPY_DAY_MIN = 100
COPY_AGE = 180

DUMP_ITEMS = """
const P = Application('Photos');
const m = P.mediaItems;
const ids = m.id(), names = m.filename(), dates = m.date(), sizes = m.size(), ws = m.width(), hs = m.height();
const out = [];
for (let i = 0; i < ids.length; i++) out.push([ids[i], names[i], dates[i] ? dates[i].toISOString() : '', sizes[i], ws[i], hs[i]]);
JSON.stringify(out);
"""
DUMP_ALBUMS = """
const P = Application('Photos');
const out = [];
function walk(c, prefix) {
  for (const a of c.albums()) out.push([prefix + a.name(), a.mediaItems.id()]);
  for (const f of c.folders()) walk(f, prefix + f.name() + '/');
}
walk(P, '');
JSON.stringify(out);
"""
HIDDEN_ASSETS = """
SELECT a.ZUUID, COALESCE(x.ZORIGINALFILENAME, a.ZFILENAME, ''), a.ZDATECREATED, COALESCE(x.ZORIGINALFILESIZE, 0),
       COALESCE(a.ZWIDTH, 0), COALESCE(a.ZHEIGHT, 0)
FROM ZASSET a LEFT JOIN ZADDITIONALASSETATTRIBUTES x ON x.ZASSET = a.Z_PK
WHERE COALESCE(a.ZHIDDEN, 0) = 1 AND COALESCE(a.ZTRASHEDSTATE, 0) = 0 AND a.ZUUID IS NOT NULL
"""
PHOTOS_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)


def jxa(script):
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(script)
    r = subprocess.run(["osascript", "-l", "JavaScript", f.name], capture_output=True, text=True, timeout=900)
    os.unlink(f.name)
    if r.returncode != 0:
        raise RuntimeError(r.stderr)
    return json.loads(r.stdout)


@contextmanager
def photos_database():
    src = PHOTOS_LIBRARY / "database/Photos.sqlite"
    with tempfile.TemporaryDirectory() as tmp:
        for suffix in ("", "-wal", "-shm"):
            if not suffix or os.path.exists(f"{src}{suffix}"):
                shutil.copyfile(f"{src}{suffix}", f"{tmp}/Photos.sqlite{suffix}")
        pdb = sqlite3.connect(f"{tmp}/Photos.sqlite")
        try:
            yield pdb
        finally:
            pdb.close()


def hidden_assets():
    try:
        with photos_database() as pdb:
            rows = pdb.execute(HIDDEN_ASSETS).fetchall()
    except (OSError, sqlite3.Error) as e:
        print(f"hidden Photos items: could not read the Photos database ({e}), skipping them")
        return []
    out = [[f"{uuid}/L0/001", name, (PHOTOS_EPOCH + timedelta(seconds=created)).isoformat() if created is not None else "", size, w, h]
           for uuid, name, created, size, w, h in rows]
    print(f"hidden Photos items: {len(out)}")
    return out


def open_index():
    INDEX.parent.mkdir(parents=True, exist_ok=True)
    index = sqlite3.connect(INDEX, timeout=120)
    index.execute("CREATE TABLE IF NOT EXISTS files (source TEXT, path TEXT, size INTEGER, mtime REAL, dataless INTEGER, sha256 TEXT, "
                  "PRIMARY KEY (source, path))")
    index.execute("CREATE TABLE IF NOT EXISTS prints (source TEXT, path TEXT, taken TEXT, width INTEGER, height INTEGER, dhash TEXT, "
                  "PRIMARY KEY (source, path))")
    return index


def event_root(dirs):
    out = []
    for d in dirs:
        out.append(d)
        if not (YEAR.fullmatch(d) or d in CONTAINERS):
            break
    return "/".join(out)


def role_of(ext, stem, sub_dirs):
    if ext in RAW:
        return "raw"
    if ext in VIDEO:
        return "video"
    if ext == "psd" or EDIT_MARK.search(stem):
        return "edit"
    if any(EDIT_DIR.search(d) and "not edited" not in d.lower() for d in sub_dirs):
        return "edit"
    return "photo"


def load_meta():
    if not CATALOG.exists():
        return {}
    db = sqlite3.connect(CATALOG)
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'file_meta'").fetchone():
        return {}
    cols = ("path", "taken", "make", "model", "lens", "software", "width", "height", "dhash")
    return {r[0]: {c: v or "" for c, v in zip(cols, r)} for r in db.execute(f"SELECT {', '.join(cols)} FROM file_meta")}


def is_original(m):
    return m["role"] == "raw" or (m["role"] == "photo" and bool(m["make"]))


def distance(a, b):
    return bin(int(a, 16) ^ int(b, 16)).count("1")


def camera_name(make, model):
    brand = MAKES.get(make.lower(), make)
    if not brand or model.lower().startswith(brand.lower()):
        return model or brand
    return f"{brand} {model}".strip()


def camera_of(members):
    src = [m for m in members if m["make"] and is_original(m)] or [m for m in members if m["make"]]
    if not src:
        return "", ""
    camera = camera_name(src[0]["make"], src[0]["model"])
    lens = next((m["lens"] for m in src if m["lens"] and camera_name(m["make"], m["model"]) == camera), "")
    return camera, lens


def origin_of(members):
    arch = [m for m in members if m["source"] == "archive"]
    names = [(m, unicodedata.normalize("NFC", m["name"])) for m in members]
    if any(p.lower() == "krea" for m in arch for p in PurePosixPath(m["path"]).parts[:-1]) or any(GENERATOR.search(m["software"]) for m in members):
        return "generated"
    if any(m["make"] and not EDITOR.search(m["software"]) for m in members) or any(m["role"] == "raw" for m in members):
        return "shot"
    if not arch and any(m["ext"] in ("heic", "dng", "mov") and PHONE_NAME.match(n) for m, n in names):
        return "shot"
    if any(m["role"] == "edit" for m in members):
        return "edit"
    for m, n in names:
        if m["ext"] != "png":
            continue
        tall = m["width"] and m["height"] / m["width"] >= 1.9 and m["width"] <= 1320
        if SCREEN_NAME.match(n) or tall or (not arch and PHONE_NAME.match(n)):
            return "screenshot"
    no_make = not any(m["make"] for m in members)
    if any(MESSENGER.match(n) for _, n in names) or (no_make and any(max(m["width"], m["height"]) == 1280 for m in members)):
        return "messenger"
    if all(m["role"] == "video" for m in members):
        stems = [n.rsplit(".", 1)[0] for _, n in names]
        if any(VIDEO_MESSENGER.match(s) for s in stems):
            return "messenger"
        if any(VIDEO_SCREEN.match(s) for s in stems):
            return "screenshot"
        if any(VIDEO_SHOT.match(s) for s in stems):
            return "shot"
    if not arch:
        for m, n in names:
            stem = n.rsplit(".", 1)[0]
            if CAMERA_NAME.match(stem):
                return "shot"
            if m["role"] == "photo" and m["ext"] not in ("png", "webp", "gif") and PHONE_STEM.match(stem) and m["width"] * m["height"] >= PHONE_PIXELS:
                return "shot"
    if arch and not any(m["meta"] for m in arch):
        return "unknown"
    return "saved"


def merge_pairs(groups):
    by_stem = defaultdict(set)
    for key, members in groups.items():
        for m in members:
            if is_original(m) and m["source"] == "archive":
                by_stem[(str(PurePosixPath(m["path"]).parent), m["stem"].lower())].add(key)
    merged = 0
    for keys in by_stem.values():
        keys = [k for k in keys if k in groups]
        if len(keys) < 2:
            continue
        times = {m["taken"] for k in keys for m in groups[k] if is_original(m) and m["meta_taken"]}
        if len(times) > 1:
            continue
        anchor = min(keys, key=lambda k: (not any(m["role"] == "photo" for m in groups[k]), k))
        for k in keys:
            if k != anchor:
                groups[anchor].extend(groups.pop(k))
                merged += 1
    return merged


def attach_edits(groups):
    by_shot = defaultdict(set)
    for key, members in groups.items():
        for m in members:
            if is_original(m) and m["meta_taken"] and m["make"]:
                by_shot[(m["root"], m["taken"], m["make"], m["model"])].add(key)
    moves = []
    for key, members in groups.items():
        if any(is_original(m) for m in members):
            continue
        for m in members:
            if m["role"] != "edit" or not m["meta_taken"] or not m["make"]:
                continue
            cands = by_shot.get((m["root"], m["taken"], m["make"], m["model"]), set()) - {key}
            target = None
            if len(cands) == 1:
                target = next(iter(cands))
            elif cands and m["dhash"]:
                scored = sorted((min((distance(m["dhash"], o["dhash"]) for o in groups[c] if is_original(o) and o["dhash"]), default=99), c)
                                for c in cands)
                if scored[0][0] <= SAME_FRAME and (len(scored) == 1 or scored[1][0] > scored[0][0]):
                    target = scored[0][1]
            if target:
                moves.append((key, m, target))
    for key, m, target in moves:
        groups[key].remove(m)
        groups[target].append(m)
        if not groups[key]:
            del groups[key]
    return len(moves)


def attach_exports(groups, asset_item):
    by_uuid = {pid.split("/", 1)[0].upper(): key for pid, key in asset_item.items()}
    attached, orphans = 0, []
    for key in list(groups):
        for m in [m for m in groups.get(key, []) if m["source"] == "archive"]:
            found = PHOTOS_EXPORT.match(m["name"])
            if not found or m["role"] == "export":
                continue
            target = by_uuid.get(found[1].upper())
            if not target:
                orphans.append(m["path"])
                continue
            m["role"] = "export"
            attached += 1
            if target == key:
                continue
            moving = [m] + [o for o in groups[key] if o["source"] == "photos" and o["name"].lower() == m["name"].lower()]
            for o in moving:
                groups[key].remove(o)
                groups[target].append(o)
                if o["source"] == "photos":
                    asset_item[o["path"]] = target
            if not groups[key]:
                del groups[key]
    return attached, orphans


def core(members):
    return [m for m in members if m["role"] != "export"] or members


def guess_date(rel, taken):
    if taken:
        return taken[:10].replace(":", "-") + taken[10:19], 1, "exif"
    m = NAME_TS.search(PurePosixPath(rel).stem)
    if m:
        y, mo, d, h, mi, s = m.groups()
        if 1 <= int(mo) <= 12 and 1 <= int(d) <= 31 and int(h) < 24:
            return f"{y}-{mo}-{d} {h}:{mi}:{s}", 1, "name"
    for part in PurePosixPath(rel).parts[:-1]:
        m = DIR_DATE.match(part)
        if m:
            return f"{m[1]}-{m[2]}-{m[3] or '01'} 00:00:00", 0, "folder"
    for part in PurePosixPath(rel).parts[:-1]:
        if YEAR.fullmatch(part):
            return f"{part}-01-01 00:00:00", 0, "year"
    return "", 0, ""


def base_date(members):
    exact = sorted((m["taken"], m["src"]) for m in members if m["taken"] and m["exact"])
    rough = sorted((m["taken"], m["src"]) for m in members if m["taken"])
    date, src = (exact or rough or [("", "")])[0]
    return date, bool(exact), src


def copy_days(groups):
    files = Counter()
    dated = Counter()
    older = Counter()
    for members in groups.values():
        for m in members:
            if m["source"] != "archive":
                continue
            day = m["filed"][:10]
            files[day] += 1
            if m["exact"] and m["src"] in ("exif", "name"):
                try:
                    taken = datetime.fromisoformat(m["taken"][:10].replace(":", "-"))
                except ValueError:
                    continue
                dated[day] += 1
                older[day] += (datetime.fromisoformat(day) - taken).days > COPY_AGE
    return {day: (n, dated[day], older[day]) for day, n in files.items()
            if n >= COPY_DAY_MIN and dated[day] and older[day] >= COPY_SHARE * dated[day]}


def file_date(members, origin, skip_days):
    date, exact, src = base_date(members)
    filed = min((m["filed"] for m in members if m["filed"] and m["filed"][:10] not in skip_days), default="")
    if exact or not filed:
        return ""
    if src == "year":
        return filed if filed[:4] == date[:4] else ""
    if origin in FILE_ORIGINS or not date:
        return filed
    return ""


def build():
    index = open_index()
    prints = {p: (t, w, h) for p, t, w, h in index.execute("SELECT path, taken, width, height FROM prints WHERE source='icloud'")}
    meta = load_meta()

    groups = defaultdict(list)
    by_name_size = {}
    unreadable = []
    for dirpath, dirnames, filenames in os.walk(ARCHIVE, onerror=unreadable.append):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in filenames:
            if name.startswith("."):
                continue
            ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
            if ext not in RAW | VIDEO | IMAGE:
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, ARCHIVE)
            dirs = list(PurePosixPath(rel).parts[:-1])
            root = event_root(dirs)
            stem = name.rsplit(".", 1)[0]
            st = os.lstat(full)
            taken, w, h = prints.get(rel, ("", 0, 0))
            fm = meta.get(rel)
            if fm and fm["taken"]:
                date, exact, src = fm["taken"], 1, "exif"
            else:
                date, exact, src = guess_date(rel, taken)
            filed = datetime.fromtimestamp(min(st.st_birthtime, st.st_mtime)).strftime("%Y-%m-%d %H:%M:%S")
            if fm and fm["width"] and fm["height"]:
                w, h = fm["width"], fm["height"]
            fm = fm or dict(make="", model="", lens="", software="", dhash="")
            m = COUNTER.match(stem)
            key = f"a|{root}|{m[1].upper()}" if m else f"a|{rel}"
            sub = dirs[len(PurePosixPath(root).parts) if root else 0 :]
            role = role_of(ext, stem, sub)
            if role == "photo" and EDITOR.search(fm["software"]):
                role = "edit"
            member = dict(source="archive", path=rel, name=name, ext=ext, size=st.st_size, role=role,
                          taken=date, exact=exact, src=src, filed=filed, width=w or 0, height=h or 0, root=root, stem=stem, meta=rel in meta,
                          meta_taken=bool(meta.get(rel, {}).get("taken")), make=fm["make"], model=fm["model"], lens=fm["lens"],
                          software=fm["software"], dhash=fm["dhash"])
            groups[key].append(member)

    if not groups and (unreadable or not ARCHIVE.is_dir()):
        reason = unreadable[0] if unreadable else f"no folder {ARCHIVE}"
        raise SystemExit(f"Could not read the archive ({reason}), the catalog is untouched. Check that PhotoHub has access to the archive folder.")

    pairs = merge_pairs(groups)
    attached = attach_edits(groups)
    by_stem_taken = {}
    for key, members in groups.items():
        for m in sorted(members, key=lambda m: not is_original(m)):
            by_name_size.setdefault((m["name"].lower(), m["size"]), key)
            if m["meta_taken"]:
                by_stem_taken.setdefault((m["stem"].lower(), m["taken"]), key)

    photos = [] if NO_PHOTOS else jxa(DUMP_ITEMS)
    hidden = [] if NO_PHOTOS else hidden_assets()
    hidden_ids = {row[0] for row in hidden}
    listed = {row[0] for row in photos}
    photos += [row for row in hidden if row[0] not in listed]
    by_date = 0
    asset_item = {}
    for pid, name, iso, size, w, h in photos:
        ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
        date = datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d %H:%M:%S") if iso else ""
        key = by_name_size.get((name.lower(), size))
        if not key and date:
            key = by_stem_taken.get((name.rsplit(".", 1)[0].lower(), date))
            by_date += bool(key)
        key = key or f"p|{pid}"
        role = "video" if ext in VIDEO else "raw" if ext in RAW else "photo"
        groups[key].append(dict(source="photos", path=pid, name=name, ext=ext, size=size or 0, role=role, taken=date,
                                exact=1, src="photos" if date else "", filed="", width=w or 0, height=h or 0, root="", stem="", meta=False, meta_taken=False,
                                make="", model="", lens="", software="", dhash=""))
        asset_item[pid] = key
    exports, orphans = attach_exports(groups, asset_item)
    albums = [] if NO_PHOTOS else jxa(DUMP_ALBUMS)

    origins = {key: origin_of(core(members)) for key, members in groups.items()}
    copy_day = copy_days(groups)
    file_dates = {key: file_date(core(members), origins[key], copy_day) for key, members in groups.items()}
    root_days = defaultdict(list)
    for key, members in groups.items():
        arch = [m for m in members if m["source"] == "archive"]
        if file_dates[key] and arch:
            root_days[arch[0]["root"]].extend(m["filed"][:10] for m in arch)
    copied = {}
    for root, days in root_days.items():
        day, n = Counter(days).most_common(1)[0]
        if len(days) >= COPY_MIN and n >= COPY_SHARE * len(days):
            copied[root] = (len(days), day, n)
    for key, members in groups.items():
        arch = [m for m in members if m["source"] == "archive"]
        if arch and arch[0]["root"] in copied:
            file_dates[key] = ""

    CATALOG.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(CATALOG, timeout=600)
    db.executescript("""
        BEGIN;
        DROP TABLE IF EXISTS item; DROP TABLE IF EXISTS member; DROP TABLE IF EXISTS album;
        CREATE TABLE item (id INTEGER PRIMARY KEY, key TEXT UNIQUE, date TEXT, date_exact INTEGER, title TEXT, root TEXT,
            in_archive INTEGER, in_photos INTEGER, has_raw INTEGER, n_edit INTEGER, n_members INTEGER,
            thumb_asset TEXT, thumb_path TEXT, is_video INTEGER, formats TEXT, origin TEXT, camera TEXT, lens TEXT, date_source TEXT);
        CREATE TABLE member (id INTEGER PRIMARY KEY, item_id INTEGER, source TEXT, path TEXT, name TEXT, ext TEXT,
            size INTEGER, role TEXT, taken TEXT, width INTEGER, height INTEGER);
        CREATE TABLE album (item_id INTEGER, album TEXT);
        CREATE TABLE IF NOT EXISTS flag (key TEXT PRIMARY KEY, phone INTEGER);
        CREATE TABLE IF NOT EXISTS date_override (key TEXT PRIMARY KEY, date TEXT, set_at TEXT);
        CREATE INDEX member_item ON member(item_id); CREATE INDEX album_item ON album(item_id);
        DROP TABLE IF EXISTS tag; CREATE TABLE tag (kind TEXT, name TEXT, item_id INTEGER); CREATE INDEX tag_kind ON tag(kind, name);
        DROP TABLE IF EXISTS photos_hidden; CREATE TABLE photos_hidden (path TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        DELETE FROM meta WHERE key = 'tags_build_id';
    """)
    ensure_mark(db)
    ensure_hidden(db)
    db.executemany("INSERT OR IGNORE INTO photos_hidden VALUES (?)", [(p,) for p in hidden_ids])
    build_id = f"{datetime.now().astimezone().isoformat(timespec='seconds')}/{uuid.uuid4()}"
    db.execute("INSERT OR REPLACE INTO meta VALUES ('build_id', ?)", (build_id,))
    overrides = dict(db.execute("SELECT key, date FROM date_override"))
    item_id = {}
    for n, (key, members) in enumerate(groups.items(), 1):
        item_id[key] = n
        date, exact, src = base_date(core(members))
        if file_dates[key]:
            date, src = file_dates[key], "file"
        if overrides.get(key):
            date, exact, src = overrides[key], 1, "manual"
        arch =[m for m in members if m["source"] == "archive"]
        phot = [m for m in members if m["source"] == "photos"]
        viewable = [m for m in arch if m["role"] in ("photo", "edit") and m["ext"] != "psd"] or [m for m in arch if m["role"] != "export"]
        root = arch[0]["root"] if arch else ""
        first = (viewable or members)[0]
        title = key.split("|")[2] if key.startswith("a|") and key.count("|") == 2 else first["name"]
        camera, lens = camera_of(core(members))
        db.execute("INSERT INTO item VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (
            n, key, date, int(exact), title, root, int(bool(arch)), int(bool(phot)),
            int(any(m["role"] == "raw" for m in members)), sum(m["role"] == "edit" for m in members), len(members),
            phot[0]["path"] if phot else "", viewable[0]["path"] if viewable else "",
            int(all(m["role"] == "video" for m in core(members))), " ".join(sorted({m["ext"].upper() for m in members})),
            origins[key], camera, lens, "folder" if src == "year" else src))
        db.executemany("INSERT INTO member (item_id, source, path, name, ext, size, role, taken, width, height) VALUES (?,?,?,?,?,?,?,?,?,?)",
                       [(n, m["source"], m["path"], m["name"], m["ext"], m["size"], m["role"], m["taken"], m["width"], m["height"]) for m in members])
    for name, ids in albums:
        db.executemany("INSERT INTO album VALUES (?, ?)", {(item_id[asset_item[i]], name) for i in ids if i in asset_item})
    db.commit()
    q = lambda s: db.execute(s).fetchone()[0]
    print(f"items: {q('SELECT COUNT(*) FROM item')}, files: {q('SELECT COUNT(*) FROM member')}")
    print(f"HEIC/JPG pairs merged: {pairs}, edits attached to their original by capture time: {attached}, Photos items matched by name and time: {by_date}")
    print(f"Photos exports in the archive attached to their Photos item by UUID: {exports}, without an item in Photos (left as is): {len(orphans)}")
    for path in orphans:
        print(f"   {path}")
    print(f"archive only: {q('SELECT COUNT(*) FROM item WHERE in_archive AND NOT in_photos')}, Photos only: {q('SELECT COUNT(*) FROM item WHERE in_photos AND NOT in_archive')}, both: {q('SELECT COUNT(*) FROM item WHERE in_photos AND in_archive')}")
    print(f"with RAW: {q('SELECT COUNT(*) FROM item WHERE has_raw')}, with edits: {q('SELECT COUNT(*) FROM item WHERE n_edit > 0')}, stacks (>1 file): {q('SELECT COUNT(*) FROM item WHERE n_members > 1')}, undated: {q('SELECT COUNT(*) FROM item WHERE date = \"\"')}")
    print("date source:", ", ".join(f"{s or '—'}: {c}" for s, c in db.execute("SELECT date_source, COUNT(*) FROM item GROUP BY 1 ORDER BY 2 DESC")))
    if copy_day:
        print("bulk copy days in the archive, file date not used:")
        for day, (total, dated, older) in sorted(copy_day.items()):
            print(f"   {day}: {total} files, {older} of {dated} with a capture date older than {COPY_AGE} days")
    if copied:
        print("folders with a shared copy date, file date not used:")
        for root, (total, day, same) in sorted(copied.items()):
            print(f"   {root or '(root)'}: {total} files, {same} of them from {day}")
    db.close()


def ensure_mark(db):
    db.execute("CREATE TABLE IF NOT EXISTS mark (key TEXT PRIMARY KEY, rating INTEGER DEFAULT 0, pick INTEGER DEFAULT 0, color TEXT DEFAULT '')")
    if "color" not in {row[1] for row in db.execute("PRAGMA table_info(mark)")}:
        db.execute("ALTER TABLE mark ADD COLUMN color TEXT DEFAULT ''")


HIDDEN = """(i.key IN (SELECT key FROM hidden_item WHERE hidden = 1)
  OR (i.in_archive = 1 AND i.root != '' AND i.key NOT IN (SELECT key FROM hidden_item WHERE hidden = 0)
      AND EXISTS (SELECT 1 FROM hidden_folder f WHERE i.root = f.path OR substr(i.root, 1, length(f.path) + 1) = f.path || '/'))
  OR EXISTS (SELECT 1 FROM member hm JOIN photos_hidden hp ON hp.path = hm.path WHERE hm.item_id = i.id AND hm.source = 'photos'))"""


def ensure_hidden(db):
    db.execute("CREATE TABLE IF NOT EXISTS hidden_item (key TEXT PRIMARY KEY, hidden INTEGER NOT NULL DEFAULT 1, set_at TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS hidden_folder (path TEXT PRIMARY KEY, set_at TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS photos_hidden (path TEXT PRIMARY KEY)")


def main():
    ap = argparse.ArgumentParser(prog="python -m photohub.catalog", description="Rebuild the catalog: items, files, albums, then tags.")
    ap.add_argument("--no-tags", action="store_true",
                    help="skip tags (people, places, trips, copies); the tag table stays empty until python -m photohub.tags runs")
    args = ap.parse_args()
    build()
    if args.no_tags:
        print("tags skipped (--no-tags): the tag table is empty, the app shows that the catalog is updating until python -m photohub.tags runs")
        return
    from . import tags
    tags.main()


if __name__ == "__main__":
    main()
