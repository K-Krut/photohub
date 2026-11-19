import json
import os
from pathlib import Path

DEFAULT_ARCHIVE = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/Photos"
SUPPORT = Path(os.environ.get("PHOTOHUB_SUPPORT", Path.home() / "Library/Application Support/PhotoHub"))
SETTINGS = SUPPORT / "config.json"


def settings():
    try:
        data = json.loads(SETTINGS.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def archive_root():
    if os.environ.get("PHOTOHUB_ARCHIVE"):
        return Path(os.environ["PHOTOHUB_ARCHIVE"]).expanduser()
    value = settings().get("archive_root")
    return Path(value).expanduser() if isinstance(value, str) and value else DEFAULT_ARCHIVE


def container_folders():
    value = settings().get("container_folders")
    return [v for v in value if isinstance(v, str) and v] if isinstance(value, list) else []


ARCHIVE = archive_root()
INDEX = Path(os.environ.get("PHOTOHUB_INDEX", SUPPORT / "hash_index.sqlite"))
CATALOG = Path(os.environ.get("PHOTOHUB_CATALOG", SUPPORT / "catalog.sqlite"))
PHOTOS_LIBRARY = Path(os.environ.get("PHOTOHUB_PHOTOS_LIBRARY", Path.home() / "Pictures/Photos Library.photoslibrary"))
NO_PHOTOS = os.environ.get("PHOTOHUB_NO_PHOTOS", "") not in ("", "0")
DEMO_PEOPLE = SUPPORT / "demo_people.json"
