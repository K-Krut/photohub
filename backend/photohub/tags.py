import json
import math
import os
import shutil
import sqlite3
import subprocess
import tempfile
from bisect import bisect_left
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path

import geonamescache

from .catalog import HIDDEN, ensure_hidden, open_index
from .config import ARCHIVE, CATALOG, DEMO_PEOPLE, INDEX, NO_PHOTOS, PHOTOS_LIBRARY

HOME_MIN_DAYS = 60
TRIP_MAX_GAP = 2
TRIP_MIN_ITEMS = 5
NOT_CAMERA = {"PNG", "WEBP", "GIF", "PSD", "BMP"}
PHOTO_PIXELS = 4_000_000
EXPORT_PIXELS = 8_000_000
CAMERA_PREFIXES = ("DSCF", "DSC_", "ZG5A")
NEAR_SECONDS = 20 * 60
PET_TYPES = {3, 4}
PEOPLE_FACES = """
SELECT f.Z_PK, COALESCE(f.ZPERSONFORFACE, f.ZPERSONFORTEMPORALDETECTEDFACES), a.ZUUID FROM ZDETECTEDFACE f
JOIN ZASSET a ON a.Z_PK = COALESCE(f.ZASSETFORFACE, f.ZASSETFORTEMPORALDETECTEDFACES)
WHERE COALESCE(f.ZHIDDEN, 0) = 0 AND COALESCE(a.ZHIDDEN, 0) = 0 AND COALESCE(a.ZTRASHEDSTATE, 0) = 0
  AND COALESCE(f.ZPERSONFORFACE, f.ZPERSONFORTEMPORALDETECTEDFACES) IS NOT NULL
"""
ORIGINS = {"shot", "edit", "screenshot", "messenger", "saved", "generated", "unknown"}

DUMP_LOCATIONS = """
const P = Application('Photos');
const m = P.mediaItems;
const ids = m.id(), locs = m.location();
const out = {};
for (let i = 0; i < ids.length; i++) if (locs[i] && locs[i][0] !== null) out[ids[i]] = locs[i];
JSON.stringify(out);
"""


def jxa(script):
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(script)
    r = subprocess.run(["osascript", "-l", "JavaScript", f.name], capture_output=True, text=True, timeout=900)
    os.unlink(f.name)
    if r.returncode != 0:
        raise RuntimeError(r.stderr)
    return json.loads(r.stdout)


def read_people(pdb, asset):
    persons = {pk: (name or "", full or "", kind, target) for pk, name, full, kind, target in
               pdb.execute("SELECT Z_PK, ZDISPLAYNAME, ZFULLNAME, ZDETECTIONTYPE, ZMERGETARGETPERSON FROM ZPERSON")}

    def final(pk):
        seen = {pk}
        while persons[pk][3] in persons and persons[pk][3] not in seen:
            pk = persons[pk][3]
            seen.add(pk)
        return pk

    ents = dict(pdb.execute("SELECT Z_NAME, Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME IN ('DetectedFace', 'Person')"))
    table = f"Z_{ents.get('DetectedFace')}REJECTEDPERSONS"
    rejected = set()
    if pdb.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", (table,)).fetchone():
        rejected = set(pdb.execute(f"SELECT Z_{ents['DetectedFace']}REJECTEDFACES, Z_{ents['Person']}REJECTEDPERSONS FROM {table}"))
    found = defaultdict(set)
    outside = 0
    for face, pk, uuid in pdb.execute(PEOPLE_FACES):
        if pk not in persons:
            continue
        top = final(pk)
        if not persons[top][0] or (face, pk) in rejected or (face, top) in rejected:
            continue
        hit = asset.get(f"{uuid}/L0/001")
        if hit:
            found[top].add(hit[0])
        else:
            outside += 1
    shared = Counter(persons[pk][0] for pk in found)
    tags = set()
    for pk, ids in found.items():
        name, full, kind, _ = persons[pk]
        label = full if shared[name] > 1 and full else name
        tags.update(("pet" if kind in PET_TYPES else "person", label, i) for i in ids)
    return tags, outside


def photos_people(asset):
    src = PHOTOS_LIBRARY / "database/Photos.sqlite"
    with tempfile.TemporaryDirectory() as tmp:
        try:
            for suffix in ("", "-wal", "-shm"):
                if not suffix or os.path.exists(f"{src}{suffix}"):
                    shutil.copyfile(f"{src}{suffix}", f"{tmp}/Photos.sqlite{suffix}")
        except FileNotFoundError:
            print(f"people and pets: Photos library not found ({src}), skipping")
            return set(), "missing"
        except PermissionError:
            print("people and pets: no access to the Photos database. Grant Full Disk Access to PhotoHub (or to the terminal you rebuild "
                  "the catalog from) in System Settings > Privacy & Security, then refresh the catalog. Skipping.")
            return set(), "no_access"
        pdb = sqlite3.connect(f"{tmp}/Photos.sqlite")
        try:
            tags, outside = read_people(pdb, asset)
        except sqlite3.Error as e:
            print(f"people and pets: could not read the Photos database ({e}), skipping")
            return set(), "error"
        finally:
            pdb.close()
    for kind, word in (("person", "people"), ("pet", "pets")):
        print(f"{word} from Photos: {len({n for k, n, _ in tags if k == kind})}, tagged items: {sum(k == kind for k, _, _ in tags)}")
    print(f"faces on Photos items that are not in the catalog: {outside}")
    return tags, "ok"


def demo_people(db):
    try:
        data = json.loads(DEMO_PEOPLE.read_text())
    except (OSError, ValueError):
        return set()
    item_of = dict(db.execute("SELECT path, item_id FROM member WHERE source = 'archive'"))
    tags = set()
    for kind, word in (("person", "people"), ("pet", "pets")):
        for name, paths in (data.get(word) or {}).items():
            tags.update((kind, name, item_of[p]) for p in paths if p in item_of)
    print(f"people and pets from {DEMO_PEOPLE.name}: {len({n for _, n, _ in tags})}, tagged items: {len(tags)}")
    return tags


def file_points(db):
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'file_meta'").fetchone():
        return []
    return db.execute("SELECT m.item_id, i.date, MIN(f.lat), MIN(f.lon) FROM file_meta f JOIN member m ON m.source = 'archive' AND m.path = f.path "
                      "JOIN item i ON i.id = m.item_id WHERE i.date_exact = 1 AND i.date != '' AND f.lat IS NOT NULL AND f.lon IS NOT NULL "
                      "AND NOT (f.lat = 0 AND f.lon = 0) GROUP BY m.item_id").fetchall()


class Cities:
    def __init__(self):
        self.grid = defaultdict(list)
        for c in geonamescache.GeonamesCache(min_city_population=15000).get_cities().values():
            self.grid[(int(c["latitude"]), int(c["longitude"]))].append((c["latitude"], c["longitude"], c["name"], c["countrycode"], c["population"]))
        self.cache = {}

    def lookup(self, lat, lon):
        key = (round(lat, 2), round(lon, 2))
        if key not in self.cache:
            near = []
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    for c in self.grid.get((int(lat) + dy, int(lon) + dx), []):
                        d = math.hypot((c[0] - lat) * 111, (c[1] - lon) * 111 * math.cos(math.radians(lat)))
                        if d < 40:
                            near.append((d, c))
            big = [x for x in near if x[0] < 12]
            pick = max(big, key=lambda x: x[1][4]) if big else (min(near, key=lambda x: x[0]) if near else None)
            self.cache[key] = (pick[1][2], pick[1][3]) if pick else None
        return self.cache[key]


def build_id(db):
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta'").fetchone():
        return None
    row = db.execute("SELECT value FROM meta WHERE key = 'build_id'").fetchone()
    return row[0] if row else None


def main():
    db = sqlite3.connect(CATALOG, timeout=600)
    build = build_id(db)
    ensure_hidden(db)
    db.commit()
    hidden = {i for (i,) in db.execute(f"SELECT i.id FROM item i WHERE {HIDDEN}")}
    asset = {path: (item_id, taken) for path, item_id, taken in db.execute("SELECT path, item_id, taken FROM member WHERE source='photos'")}
    cities = Cities()
    locations = {} if NO_PHOTOS else jxa(DUMP_LOCATIONS)

    day_cities = defaultdict(Counter)
    city_days = defaultdict(set)
    tags = set()
    for pid, (lat, lon) in locations.items():
        if pid not in asset:
            continue
        item_id, taken = asset[pid]
        city = cities.lookup(lat, lon)
        if not city:
            continue
        tags.add(("place", city[0], item_id))
        tags.add(("country", city[1], item_id))
        if taken and item_id not in hidden:
            day_cities[taken[:10]][city] += 1
            city_days[city].add(taken[:10])
    if NO_PHOTOS:
        for item_id, taken, lat, lon in file_points(db):
            if item_id in hidden:
                continue
            city = cities.lookup(lat, lon)
            if city:
                day_cities[taken[:10]][city] += 1
                city_days[city].add(taken[:10])

    home = {c for c, days in city_days.items() if len(days) >= HOME_MIN_DAYS}
    trips = []
    current = None
    for day in sorted(day_cities):
        d = date.fromisoformat(day)
        away = [c for c, n in day_cities[day].most_common() if c not in home and n >= 2]
        at_home = any(c in home for c in day_cities[day]) and not away
        if at_home or not away:
            if at_home and current:
                trips.append(current)
                current = None
            continue
        if current and (d - current["end"]).days > TRIP_MAX_GAP:
            trips.append(current)
            current = None
        if not current:
            current = {"start": d, "end": d, "cities": []}
        current["end"] = d
        for c in away:
            if c[0] not in current["cities"]:
                current["cities"].append(c[0])
    if current:
        trips.append(current)

    db.execute("BEGIN IMMEDIATE")
    if build_id(db) != build:
        db.rollback()
        print("tags not written: the catalog was rebuilt while they were computed; the new build will compute them")
        return
    own_archive = "EXISTS (SELECT 1 FROM member a WHERE a.item_id = item.id AND a.source = 'archive' AND a.role != 'export')"
    photos_only = {i for (i,) in db.execute(f"SELECT id FROM item WHERE NOT {own_archive}")}
    geotagged = {asset[pid][0] for pid in locations if pid in asset} & photos_only
    db.executemany("UPDATE item SET origin = 'shot' WHERE id = ? AND origin != 'generated'", [(i,) for i in geotagged])

    located = {item_id for kind, _, item_id in tags if kind == "place"}
    rows = db.execute(
        f"SELECT i.id, i.date, {own_archive.replace('item.id', 'i.id')}, i.formats, i.is_video, i.title, COALESCE(MAX(m.width * m.height), 0) FROM item i "
        "LEFT JOIN member m ON m.item_id = i.id WHERE i.date != '' AND i.date_exact = 1 GROUP BY i.id")
    items = []
    for item_id, taken, in_archive, formats, is_video, title, pixels in rows:
        if item_id in hidden:
            keep = False
        elif item_id in located:
            keep = True
        elif set(formats.split()) <= NOT_CAMERA:
            keep = pixels >= EXPORT_PIXELS or title.upper().startswith(CAMERA_PREFIXES)
        elif in_archive:
            keep = True
        else:
            keep = not is_video and pixels >= PHOTO_PIXELS
        if keep:
            items.append((item_id, taken))
    kept = 0
    for trip in trips:
        start, end = trip["start"].isoformat(), (trip["end"] + timedelta(days=1)).isoformat()
        inside = [i for i, d in items if start <= d[:10] < end]
        if len(inside) < TRIP_MIN_ITEMS:
            continue
        kept += 1
        name = f'{trip["start"].isoformat()}|{trip["end"].isoformat()}|{" · ".join(trip["cities"][:5])}'
        tags.update(("trip", name, i) for i in inside)
    db.execute("DROP TABLE IF EXISTS exact_copy")
    db.execute("CREATE TABLE exact_copy (sha256 TEXT, path TEXT, size INTEGER, item_key TEXT, in_photos INTEGER)")
    moved = []
    copies = []
    if INDEX.exists():
        index = open_index()
        known = {p: (s, h) for p, s, h in index.execute("SELECT path, size, sha256 FROM files WHERE source = 'icloud'")}
        members = db.execute("SELECT m.path, m.name, m.size, i.key, i.in_photos, i.id FROM member m JOIN item i ON i.id = m.item_id "
                             "WHERE m.source = 'archive' ORDER BY m.path").fetchall()
        missing = [m for m in members if m[0] not in known]
        if missing:
            gone = defaultdict(list)
            for p, (s, _) in known.items():
                if not os.path.lexists(ARCHIVE / p):
                    gone[(Path(p).name, s)].append(p)
            for path, name, size, *_ in missing:
                cands = gone.get((name, size))
                if cands and len({known[c][1] for c in cands}) == 1:
                    old = cands.pop()
                    known[path] = known.pop(old)
                    moved.append((old, path))
            for old, new in moved:
                index.execute("UPDATE files SET path = ? WHERE source = 'icloud' AND path = ?", (new, old))
                index.execute("UPDATE OR IGNORE prints SET path = ? WHERE source = 'icloud' AND path = ?", (new, old))
            index.commit()
        by_sha = defaultdict(list)
        for path, _, size, key, in_photos, item_id in members:
            sha = known.get(path, (None, None))[1]
            if sha:
                by_sha[sha].append((path, size, key, in_photos, item_id))
        for sha, group in by_sha.items():
            if len(group) > 1:
                copies += [(sha, path, size, key, in_photos) for path, size, key, in_photos, _ in group]
                tags.update(("dup", "exact", item_id) for *_, item_id in group)
        db.executemany("INSERT INTO exact_copy VALUES (?, ?, ?, ?, ?)", copies)
    place_of = {}
    for kind, name, item_id in sorted(tags):
        if kind == "place":
            place_of.setdefault(item_id, [name, None])
    for kind, name, item_id in sorted(tags):
        if kind == "country" and item_id in place_of and place_of[item_id][1] is None:
            place_of[item_id][1] = name
    has_meta = db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'file_meta'").fetchone()
    own_gps = 0
    if has_meta:
        for item_id, lat, lon in db.execute("SELECT m.item_id, f.lat, f.lon FROM file_meta f JOIN member m ON m.source = 'archive' AND m.path = f.path "
                                            "WHERE f.lat IS NOT NULL AND f.lon IS NOT NULL AND NOT (f.lat = 0 AND f.lon = 0) ORDER BY m.path"):
            city = cities.lookup(lat, lon)
            if city and item_id not in place_of:
                place_of[item_id] = list(city)
                tags.add(("place", city[0], item_id))
                tags.add(("country", city[1], item_id))
                own_gps += 1
    anchors = sorted((datetime.fromisoformat(d), i) for i, d in db.execute("SELECT id, date FROM item WHERE date_exact = 1 AND date != ''") if i in place_of)
    moments = [a[0] for a in anchors]
    nearby = 0
    for item_id, d in db.execute("SELECT id, date FROM item WHERE date_exact = 1 AND date != '' AND origin IN ('shot', 'edit')").fetchall():
        if item_id in place_of:
            continue
        t = datetime.fromisoformat(d)
        k = bisect_left(moments, t)
        best = min((anchors[j] for j in (k - 1, k) if 0 <= j < len(anchors)), key=lambda a: abs((a[0] - t).total_seconds()), default=None)
        if best and abs((best[0] - t).total_seconds()) <= NEAR_SECONDS:
            name, country = place_of[best[1]]
            tags.add(("place", name, item_id))
            if country:
                tags.add(("country", country, item_id))
            nearby += 1
    for item_id, origin in db.execute("SELECT id, origin FROM item"):
        if origin in ORIGINS:
            tags.add(("origin", origin, item_id))
    people, status = (set(), "off") if NO_PHOTOS else photos_people(asset)
    demo = demo_people(db)
    if demo:
        people, status = people | demo, "ok"
    tags |= people
    db.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
    db.execute("INSERT OR REPLACE INTO meta VALUES ('photos_people', ?)", (status,))
    if build:
        db.execute("INSERT OR REPLACE INTO meta VALUES ('tags_build_id', ?)", (build,))
    else:
        db.execute("DELETE FROM meta WHERE key = 'tags_build_id'")
    db.execute("DROP TABLE IF EXISTS tag")
    db.execute("CREATE TABLE tag (kind TEXT, name TEXT, item_id INTEGER)")
    db.execute("CREATE INDEX tag_kind ON tag(kind, name)")
    db.executemany("INSERT INTO tag VALUES (?, ?, ?)", tags)
    db.commit()
    print(f"exact copies: groups {len({c[0] for c in copies})}, files {len(copies)}, items {len({c[3] for c in copies})}; "
          f"paths matched as moved: {len(moved)}")
    print(f"place from the file's GPS: {own_gps}, place from the nearest item in time (up to 20 min): {nearby}")
    for origin, n in db.execute("SELECT origin, COUNT(*) FROM item GROUP BY origin ORDER BY 2 DESC"):
        print(f"   {origin}: {n}")
    print("home:", sorted(f"{c[0]} ({len(city_days[c])} days)" for c in home))
    print(f"trips: {kept}, places: {db.execute('SELECT COUNT(DISTINCT name) FROM tag WHERE kind=\"place\"').fetchone()[0]}")
    for name, n in db.execute("SELECT name, COUNT(*) FROM tag WHERE kind='trip' GROUP BY name ORDER BY name DESC"):
        print("  ", name.replace("|", "  "), f"[{n}]")


if __name__ == "__main__":
    main()
