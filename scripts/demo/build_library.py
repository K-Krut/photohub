import argparse
import csv
import json
import os
import random
import shutil
import sqlite3
import subprocess
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFont, ImageOps
from pillow_heif import register_heif_opener

register_heif_opener()

LONG_SIDE = 2048
USER_AGENT = "photohub-demo/1.0"
PLACES = {
    "lisbon": (38.7110, -9.1366),
    "porto": (41.1496, -8.6110),
    "rome": (41.8986, 12.4769),
    "pisa": (43.7230, 10.3966),
    "prague": (50.0870, 14.4208),
    "nyc": (40.7580, -73.9855),
    "sf": (37.8080, -122.4177),
    "paris": (48.8584, 2.2945),
    "reykjavik": (64.1466, -21.9426),
}
CAMERAS = {
    "fuji": dict(prefix="DSCF", start=2001, digits=4, ext=".JPG", make="FUJIFILM", model="X-T4", lens="XF16-55mmF2.8 R LM WR", focal=(16, 55)),
    "sony": dict(prefix="DSC", start=4501, digits=5, ext=".JPG", make="SONY", model="ILCE-7M3", lens="FE 24-70mm F2.8 GM", focal=(24, 70)),
    "iphone": dict(prefix="IMG_", start=3101, digits=4, ext=".HEIC", make="Apple", model="iPhone 15 Pro",
                   lens="iPhone 15 Pro back triple camera 6.765mm f/1.78", focal=(6.765, 6.765)),
}
LIGHTROOM = "Adobe Photoshop Lightroom Classic 13.0 (Macintosh)"


def fetch(url, dest):
    if dest.exists() and dest.stat().st_size > 0:
        return
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
    part = dest.with_name(dest.name + ".part")
    part.write_bytes(data)
    os.replace(part, dest)


def download(ids, cache):
    (cache / "info").mkdir(parents=True, exist_ok=True)
    (cache / "images").mkdir(parents=True, exist_ok=True)

    def one(pid):
        info_file = cache / "info" / f"{pid}.json"
        fetch(f"https://picsum.photos/id/{pid}/info", info_file)
        info = json.loads(info_file.read_text())
        w, h = info["width"], info["height"]
        scale = LONG_SIDE / max(w, h)
        fetch(f"https://picsum.photos/id/{pid}/{round(w * scale)}/{round(h * scale)}.jpg", cache / "images" / f"{pid}.jpg")
        return info

    with ThreadPoolExecutor(8) as pool:
        infos = list(pool.map(one, sorted(set(ids))))
    print(f"demo images: {len(infos)} in {cache / 'images'}")
    return {str(i["id"]): i for i in infos}


def grade(im):
    im = ImageEnhance.Contrast(im).enhance(1.18)
    im = ImageEnhance.Color(im).enhance(1.3)
    r, g, b = im.split()
    r = r.point(lambda v: min(255, int(v * 1.07 + 6)))
    b = b.point(lambda v: int(v * 0.9))
    return Image.merge("RGB", (r, g, b))


def sepia(im):
    gray = ImageOps.grayscale(im)
    return ImageOps.colorize(ImageOps.autocontrast(gray, cutoff=2), black="#2b2118", white="#f3e6cf")


def screenshot(im, caption):
    w, h = 1179, 2556
    canvas = Image.new("RGB", (w, h), "#f2f2f7")
    draw = ImageDraw.Draw(canvas)
    big, small = ImageFont.load_default(size=64), ImageFont.load_default(size=40)
    draw.text((70, 40), "9:41", fill="black", font=small)
    draw.text((70, 200), caption, fill="black", font=big)
    photo = ImageOps.fit(im, (w - 140, 900))
    mask = Image.new("L", photo.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, *photo.size), 48, fill=255)
    canvas.paste(photo, (70, 340), mask)
    for n in range(5):
        y = 1320 + n * 190
        draw.rounded_rectangle((70, y, w - 70, y + 150), 36, fill="white")
        draw.rounded_rectangle((110, y + 40, 110 + 360 + n * 70, y + 70), 15, fill="#c7c7cc")
        draw.rounded_rectangle((110, y + 90, 110 + 220 + n * 40, y + 110), 10, fill="#e5e5ea")
    draw.rounded_rectangle((w // 2 - 180, h - 40, w // 2 + 180, h - 28), 6, fill="black")
    return canvas


def save(im, path, ext):
    path.parent.mkdir(parents=True, exist_ok=True)
    if ext in (".heic", ".heif"):
        im.save(path, "HEIF", quality=82)
    elif ext == ".png":
        im.save(path, "PNG", optimize=True)
    else:
        im.save(path, "JPEG", quality=90)


def exif_args(path, when, camera, place, rng, software=None):
    args = [f"-DateTimeOriginal={when:%Y:%m:%d %H:%M:%S}", f"-CreateDate={when:%Y:%m:%d %H:%M:%S}"]
    if camera in CAMERAS:
        c = CAMERAS[camera]
        lo, hi = c["focal"]
        args += [f"-Make={c['make']}", f"-Model={c['model']}", f"-LensModel={c['lens']}",
                 f"-FocalLength={round(rng.uniform(lo, hi))}", f"-FNumber={rng.choice([1.8, 2.8, 4, 5.6, 8])}",
                 f"-ExposureTime=1/{rng.choice([60, 125, 250, 500, 1000])}", f"-ISO={rng.choice([100, 160, 200, 400, 800])}"]
    if software:
        args.append(f"-Software={software}")
    if place:
        lat, lon = PLACES[place]
        lat += rng.uniform(-0.012, 0.012)
        lon += rng.uniform(-0.016, 0.016)
        args += [f"-GPSLatitude={abs(lat):.6f}", f"-GPSLatitudeRef={'N' if lat >= 0 else 'S'}",
                 f"-GPSLongitude={abs(lon):.6f}", f"-GPSLongitudeRef={'E' if lon >= 0 else 'W'}"]
    return args + [str(path), "-execute"]


def build(manifest, cache, archive, support):
    rows = list(csv.DictReader(manifest.open(encoding="utf-8"), delimiter="\t"))
    infos = download([r["id"] for r in rows], cache)
    if archive.exists():
        shutil.rmtree(archive)
    archive.mkdir(parents=True)
    rng = random.Random(42)
    counters = {k: c["start"] for k, c in CAMERAS.items()}
    day_clock = {}
    exif, times, copies = [], {}, []
    people, pets, seeds = {}, {}, []
    scans = 0
    for row in rows:
        extras = dict((e.split("=", 1) + [""])[:2] for e in row["extras"].split(",") if e)
        source = Image.open(cache / "images" / f"{row['id']}.jpg").convert("RGB")
        camera, folder = row["camera"], archive / row["folder"]
        when = None
        if row["day"]:
            day = datetime.fromisoformat(row["day"])
            clock = day_clock.setdefault(row["day"], day.replace(hour=9, minute=rng.randint(5, 50)))
            when = clock
            day_clock[row["day"]] = clock + timedelta(minutes=rng.randint(17, 75), seconds=rng.randint(0, 59))
        if "name" in extras:
            name = extras["name"]
        elif camera in CAMERAS:
            c = CAMERAS[camera]
            name = f"{c['prefix']}{counters[camera]:0{c['digits']}d}{c['ext']}"
            counters[camera] += 1
        else:
            scans += 1
            name = f"Scan {scans:03d}.jpg"
        path = folder / name
        ext = path.suffix.lower()
        if camera == "screenshot":
            image = screenshot(source, extras.get("caption", ""))
        elif "noexif" in extras:
            image = sepia(source)
        else:
            image = source
        save(image, path, ext)
        rel = str(path.relative_to(archive))
        if when and "noexif" not in extras and camera != "none":
            exif += exif_args(path, when, camera, row["place"], rng)
        if when:
            times[path] = when
        stacked = [rel]
        if "edit" in extras:
            edit = folder / f"{path.stem}_LR.jpg"
            save(grade(source), edit, ".jpg")
            exif += exif_args(edit, when, camera, row["place"], random.Random(row["id"]), LIGHTROOM)
            times[edit] = when + timedelta(days=rng.randint(1, 20))
            stacked.append(str(edit.relative_to(archive)))
        if "export" in extras:
            export = folder / "Export" / f"{path.stem}.jpg"
            save(ImageEnhance.Brightness(grade(source)).enhance(1.05).resize((1600, round(1600 * source.height / source.width))), export, ".jpg")
            exif += exif_args(export, when, camera, row["place"], random.Random(row["id"]), LIGHTROOM)
            times[export] = when + timedelta(days=30)
        if "copy" in extras:
            copies.append((path, archive / extras["copy"] / f"{path.stem} copy{path.suffix}"))
        for name in filter(None, extras.get("people", "").split("+")):
            people.setdefault(name, []).append(rel)
        if extras.get("pet"):
            pets.setdefault(extras["pet"], []).append(rel)
        seed = {k: extras[k] for k in ("rate", "label", "tag") if extras.get(k)}
        seed.update({k: True for k in ("pick", "reject", "phone") if k in extras})
        if seed:
            seeds.append(dict(seed, path=rel))
    argfile = support / "demo_exif.args"
    argfile.write_text("\n".join(exif[:-1]) + "\n", encoding="utf-8")
    exiftool = shutil.which("exiftool") or "/opt/homebrew/bin/exiftool"
    subprocess.run([exiftool, "-@", str(argfile), "-common_args", "-overwrite_original", "-q", "-charset", "filename=utf8"], check=True)
    argfile.unlink()
    for path, when in times.items():
        stamp = when.timestamp()
        os.utime(path, (stamp, stamp))
    for src, dst in copies:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        stamp = src.stat().st_mtime
        os.utime(dst, (stamp, stamp))
    (support / "demo_people.json").write_text(json.dumps({"people": people, "pets": pets}, indent=2, ensure_ascii=False))
    (support / "demo_seeds.json").write_text(json.dumps(seeds, indent=2, ensure_ascii=False))
    credits = ["id\tauthor\tsource"] + [f"{i}\t{infos[i]['author']}\t{infos[i]['url']}" for i in sorted(infos, key=int)]
    (archive.parent / "CREDITS.tsv").write_text("\n".join(credits) + "\n", encoding="utf-8")
    files = [p for p in archive.rglob("*") if p.is_file()]
    print(f"demo archive: {len(files)} files, {sum(p.stat().st_size for p in files) / 1e6:.0f} MB in {archive}")


def seed(support, catalog):
    seeds = json.loads((support / "demo_seeds.json").read_text())
    db = sqlite3.connect(catalog)
    key_of = dict(db.execute("SELECT m.path, i.key FROM member m JOIN item i ON i.id = m.item_id WHERE m.source = 'archive'"))
    db.execute("CREATE TABLE IF NOT EXISTS flag (key TEXT PRIMARY KEY, phone INTEGER)")
    db.execute("CREATE TABLE IF NOT EXISTS user_tag (key TEXT, tag TEXT, PRIMARY KEY (key, tag))")
    db.execute("CREATE TABLE IF NOT EXISTS mark (key TEXT PRIMARY KEY, rating INTEGER DEFAULT 0, pick INTEGER DEFAULT 0, color TEXT DEFAULT '')")
    done = 0
    for s in seeds:
        key = key_of.get(s["path"])
        if not key:
            continue
        pick = 1 if s.get("pick") else -1 if s.get("reject") else 0
        db.execute("INSERT OR REPLACE INTO mark (key, rating, pick, color) VALUES (?, ?, ?, ?)", (key, int(s.get("rate", 0)), pick, s.get("label", "")))
        if s.get("phone"):
            db.execute("INSERT OR REPLACE INTO flag (key, phone) VALUES (?, 1)", (key,))
        if s.get("tag"):
            db.execute("INSERT OR IGNORE INTO user_tag VALUES (?, ?)", (key, s["tag"]))
        done += 1
    db.commit()
    print(f"demo marks, flags and tags: {done} items")


def main():
    ap = argparse.ArgumentParser(prog="build_library.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("build")
    p.add_argument("--manifest", type=Path, required=True)
    p.add_argument("--cache", type=Path, required=True)
    p.add_argument("--archive", type=Path, required=True)
    p.add_argument("--support", type=Path, required=True)
    p = sub.add_parser("seed")
    p.add_argument("--support", type=Path, required=True)
    p.add_argument("--catalog", type=Path, required=True)
    args = ap.parse_args()
    if args.cmd == "build":
        args.support.mkdir(parents=True, exist_ok=True)
        build(args.manifest, args.cache, args.archive, args.support)
    else:
        seed(args.support, args.catalog)


if __name__ == "__main__":
    sys.exit(main())
