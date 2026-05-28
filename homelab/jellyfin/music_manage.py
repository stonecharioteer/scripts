#!/usr/bin/env python3
"""Organize a messy music directory into a Jellyfin-friendly layout.

The script walks the current directory by default and infers destinations like:

    Artist/Album (Year)/01 - Track.ext
    Artist/Album (Year)/Disc 01/01 - Track.ext

It is dry-run by default. Pass --apply to move files.
"""

from __future__ import annotations

import argparse
import csv
import re
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Union


AUDIO_EXTS = {
    ".aac",
    ".aiff",
    ".alac",
    ".ape",
    ".flac",
    ".m4a",
    ".m4b",
    ".mp3",
    ".ogg",
    ".opus",
    ".wav",
    ".wma",
}
IMAGE_EXTS = {".bmp", ".gif", ".jpeg", ".jpg", ".png", ".webp"}
JUNK_EXTS = {
    ".accurip",
    ".bup",
    ".cue",
    ".epub",
    ".ifo",
    ".log",
    ".m3u",
    ".m3u8",
    ".mkv",
    ".mp4",
    ".nfo",
    ".pdf",
    ".sfv",
    ".srr",
    ".txt",
    ".url",
    ".vob",
}

KNOWN_ARTIST_PREFIXES = (
    "Of Monsters and Men",
    "Radiohead",
)

NOISE_WORDS = (
    r"mp3",
    r"flac",
    r"320\s*kbps",
    r"320ak",
    r"320",
    r"24\s*bit[- ]?96\s*khz",
    r"24bit[- ]?96khz",
    r"16\s*bit[- ]?44(?:\.1)?\s*khz",
    r"16[- ]44",
    r"24[- ]44",
    r"24[- ]96",
    r"pbthal",
    r"songs collection",
    r"vtwin88cube",
    r"pmedia",
    r"hunter",
    r"channel neo",
    r"cdrip",
    r"remastered",
    r"bubanee",
)


@dataclass(frozen=True)
class Destination:
    source: Path
    target: Path
    reason: str


@dataclass(frozen=True)
class Skip:
    source: Path
    reason: str


@dataclass(frozen=True)
class Plan:
    discovered: int
    destinations: list[Destination]
    skips: list[Skip]
    warnings: list[str]


def clean_spaces(value: str) -> str:
    value = value.replace(r"\(", "(").replace(r"\)", ")")
    value = value.replace("_", " ")
    value = re.sub(r"\s+", " ", value)
    return value.strip(" .-_")


def sanitize_component(value: str) -> str:
    value = clean_spaces(value)
    value = re.sub(r'[\x00-\x1f:<>"/\\|?*]+', " - ", value)
    value = re.sub(r"\s*-\s*-\s*", " - ", value)
    value = re.sub(r"\s+", " ", value)
    return value.strip(" .-_") or "Unknown"


def normalize_artist(value: str) -> str:
    value = sanitize_component(strip_noise(value))
    if value.isupper() and len(value) > 4:
        value = value.title()
    replacements = {
        "Ac Dc": "ACDC",
        "Acdc": "ACDC",
        "Lofi Girl": "Lofi Girl",
    }
    return replacements.get(value, value)


def strip_noise(value: str) -> str:
    value = value.replace("\u2b50\ufe0f", " ")
    value = re.sub(r"\[[^\]]*(?:" + "|".join(NOISE_WORDS) + r")[^\]]*\]", " ", value, flags=re.I)
    value = re.sub(r"\((?:\s*(?:" + "|".join(NOISE_WORDS) + r")\s*)+\)", " ", value, flags=re.I)
    value = re.sub(r"\b(?:" + "|".join(NOISE_WORDS) + r")\b", " ", value, flags=re.I)
    value = re.sub(r"\s+", " ", value)
    return value.strip(" .-_")


def strip_artist_prefix(value: str, artist: str) -> str:
    artist_re = re.escape(artist).replace(r"\ ", r"[\s_-]+")
    value = re.sub(rf"^{artist_re}\s+(?=\[\d{{4}}\])", "", value, flags=re.I)
    value = re.sub(rf"^{artist_re}\s*[-_.]\s*", "", value, flags=re.I)
    value = re.sub(rf"^{artist_re}[-_]", "", value, flags=re.I)
    return value


def clean_album_label(value: str) -> str:
    value = clean_spaces(value)
    value = re.sub(r"\[\s*\]", " ", value)
    value = re.sub(r"\(\s*\)", " ", value)
    value = re.sub(r"\(\s+", "(", value)
    value = re.sub(r"\s+\)", ")", value)
    value = re.sub(r"\s+\)+", ")", value)
    value = re.sub(r"\(\s*-\s*", "(", value)
    value = re.sub(r"\s*-\s*\)", ")", value)
    value = re.sub(r"\s+\d{2,3}$", " ", value)
    value = re.sub(r"\s+", " ", value)
    return value.strip(" .-_")


def parse_album(value: str, artist: Optional[str] = None) -> str:
    original = value
    value = strip_noise(value)

    if artist:
        value = strip_artist_prefix(value, artist)

    # [1995] The X Factor [2 CD]
    match = re.match(r"^\[(?P<year>\d{4})\]\s*(?P<name>.+)$", value)
    if match:
        name = re.sub(r"\[(?:\d+\s*)?CD\]", "", match.group("name"), flags=re.I)
        return sanitize_component(f"{clean_spaces(name)} ({match.group('year')})")

    # 2001 - Is This It
    match = re.match(r"^(?P<year>\d{4})\s*[-_.]\s*(?P<name>.+)$", value)
    if match:
        return sanitize_component(f"{clean_spaces(match.group('name'))} ({match.group('year')})")

    # Metallica - 2008 - Death Magnetic
    if artist:
        match = re.match(rf"^{re.escape(artist)}\s*[-_.]\s*(?P<year>\d{{4}})\s*[-_.]\s*(?P<name>.+)$", value, flags=re.I)
        if match:
            return sanitize_component(f"{clean_spaces(match.group('name'))} ({match.group('year')})")

    # Tool-Aenima-CD-FLAC-1996-SCORN
    if artist and re.match(rf"^{re.escape(artist)}[-_]", original, flags=re.I):
        scene = re.sub(rf"^{re.escape(artist)}[-_]", "", original, flags=re.I)
        scene = re.sub(r"[-_](?:CD|CDEP|FLAC|MP3|SCORN|DeVOiD|ACAB)(?:[-_]|$).*", " ", scene, flags=re.I)
        year = re.search(r"(19|20)\d{2}", original)
        if year:
            scene = re.sub(r"(19|20)\d{2}.*", "", scene)
            return sanitize_component(f"{clean_spaces(scene)} ({year.group(0)})")
        return sanitize_component(clean_spaces(scene))

    years = re.findall(r"(?:19|20)\d{2}", value)
    name = value
    if artist:
        name = strip_artist_prefix(name, artist)

    # Keep descriptive parentheses, but remove trailing uploader/format junk.
    name = re.sub(r"\[[^\]]+\]", " ", name)
    name = re.sub(r"\s+", " ", name).strip()

    if years:
        year = years[-1]
        name_without_year = re.sub(rf"\b{year}\b", " ", name)
        name_without_year = clean_album_label(name_without_year)
        return sanitize_component(f"{name_without_year} ({year})")

    return sanitize_component(name)


def parse_artist_from_release(value: str) -> Optional[str]:
    # The Beatles [2009] Greatest Hits CDRip [Remastered][Bubanee]
    match = re.match(r"^(?P<artist>.+?)\s+\[(?P<year>\d{4})\]\s+(?P<album>.+)$", value)
    if match:
        return normalize_artist(match.group("artist"))

    match = re.match(r"^(?P<artist>.+?)\s*-\s*discography\b", value, flags=re.I)
    if match:
        return normalize_artist(match.group("artist"))

    match = re.match(r"^(?P<artist>.+?)\s*-\s*(?P<rest>.+)$", value)
    if match and match.group("rest").strip():
        return normalize_artist(match.group("artist"))

    return None


def is_disc_dir(value: str) -> tuple[bool, str]:
    match = re.search(r"\b(?:disc|cd)\s*(?P<num>\d+)\b(?:\s*[-_]\s*(?P<label>.*))?", value, flags=re.I)
    if not match:
        roman = re.search(r"\b(?:disc|cd)\s*(?P<num>i{1,3}|iv|v|vi{0,3}|ix|x)\b(?:\s*[-_]\s*(?P<label>.*))?", value, flags=re.I)
        if not roman:
            return False, ""
        roman_values = {"i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6, "vii": 7, "viii": 8, "ix": 9, "x": 10}
        label = clean_spaces(roman.group("label") or "")
        disc = f"Disc {roman_values[roman.group('num').lower()]:02d}"
        return True, sanitize_component(f"{disc} - {label}" if label else disc)
    label = clean_spaces(match.group("label") or "")
    disc = f"Disc {int(match.group('num')):02d}"
    return True, sanitize_component(f"{disc} - {label}" if label else disc)


def parse_track_name(filename: str, artist: Optional[str]) -> str:
    stem = Path(filename).stem
    ext = Path(filename).suffix.lower()
    stem = clean_spaces(stem)

    match = re.match(r"^(?P<num>\d{1,3})\s*[.-]\s*(?P<title>.+)$", stem)
    if match:
        title = clean_spaces(match.group("title"))
        if artist:
            title = strip_artist_prefix(title, artist)
        return sanitize_component(f"{int(match.group('num')):02d} - {title}") + ext

    match = re.match(r"^(?P<num>\d{1,3})[-_](?P<title>.+)$", stem)
    if match:
        title = clean_spaces(match.group("title"))
        if artist:
            title = strip_artist_prefix(title, artist)
        return sanitize_component(f"{int(match.group('num')):02d} - {title}") + ext

    match = re.match(r"^(?P<num>\d{1,3})\s+(?P<title>.+)$", stem)
    if match:
        title = clean_spaces(match.group("title"))
        if artist:
            title = strip_artist_prefix(title, artist)
        return sanitize_component(f"{int(match.group('num')):02d} - {title}") + ext

    return sanitize_component(stem) + ext


def infer_context(rel_path: Path, include_podcasts: bool) -> Optional[tuple[str, str, Optional[str]]]:
    parts = rel_path.parts
    if len(parts) < 2:
        return None

    top = parts[0]
    if "podcast" in top.lower() and not include_podcasts:
        return None

    if top.lower() == "lofi-girl":
        return "Various Artists", "Lofi Girl", None

    artist = parse_artist_from_release(top)
    album_index = 1

    if artist and re.search(r"\bdiscography\b", top, flags=re.I):
        if len(parts) < 3:
            return None
        album = parse_album(parts[1], artist)
        album_index = 1
    elif artist:
        album = parse_album(top, artist)
        album_index = 0
        if len(parts) >= 3 and clean_spaces(parts[1]).lower() in clean_spaces(album).lower():
            album_index = 1
    else:
        known_artist = next((prefix for prefix in KNOWN_ARTIST_PREFIXES if top.lower().startswith(prefix.lower() + " ")), None)
        if known_artist:
            artist = normalize_artist(known_artist)
            album_source = top[len(known_artist) :].strip()
            if artist.lower() == "radiohead":
                album_source = re.sub(r"\b1997\b", " ", album_source)
                album_source = re.sub(r"\b\d+\s*cd\b", " ", album_source, flags=re.I)
            album = parse_album(album_source, artist)
            album_index = 0
        elif len(parts) >= 3 and not re.search(r"\b(recordings|downloads?)\b", top, flags=re.I):
            # Treat a simple top-level directory as an artist root when the
            # next component looks like a release.
            artist = normalize_artist(top)
            album = parse_album(parts[1], artist)
            album_index = 1
        else:
            return None

    disc = None
    for component in parts[album_index + 1 : -1]:
        ok, disc_name = is_disc_dir(component)
        if ok:
            disc = disc_name
            break

    return artist, album, disc


def should_keep_image(rel_path: Path) -> bool:
    stem = rel_path.stem.lower()
    parent_names = {part.lower() for part in rel_path.parts[:-1]}
    if "artwork" in parent_names:
        return any(word in stem for word in ("front", "cover", "folder"))
    return stem in {"cover", "folder", "front", "front 1"} or "cover" in stem


def image_target(rel_path: Path, artist: str, album: str) -> Path:
    album_root = Path(sanitize_component(artist)) / sanitize_component(album)
    ext = rel_path.suffix.lower()
    if should_keep_image(rel_path):
        return album_root / f"folder{ext}"
    return album_root / "Artwork" / (sanitize_component(rel_path.stem) + ext)


def target_for_path(rel_path: Path, include_podcasts: bool) -> Union[Destination, Skip]:
    ext = rel_path.suffix.lower()

    if rel_path.parts and rel_path.parts[0].lower() == "recordings":
        return Skip(rel_path, "recordings intentionally left untouched")

    context = infer_context(rel_path, include_podcasts)
    if context is None:
        return Skip(rel_path, "could not infer artist/album or podcast skipped")

    artist, album, disc = context
    base = Path(sanitize_component(artist)) / sanitize_component(album)
    if disc:
        base /= sanitize_component(disc)

    if ext in AUDIO_EXTS:
        return Destination(rel_path, base / parse_track_name(rel_path.name, artist), "audio")

    if ext in IMAGE_EXTS:
        reason = "cover art" if should_keep_image(rel_path) else "additional artwork"
        return Destination(rel_path, image_target(rel_path, artist, album), reason)

    if ext in JUNK_EXTS:
        return Skip(rel_path, "non-library sidecar/junk file")

    return Skip(rel_path, f"unsupported extension: {ext or '(none)'}")


def is_relative_to(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def iter_source_files(source_root: Path, excluded_roots: list[Path], excluded_files: list[Path]) -> list[Path]:
    files: list[Path] = []
    for path in sorted(source_root.rglob("*")):
        if not path.is_file():
            continue
        resolved = path.resolve()
        if resolved in excluded_files:
            continue
        if any(is_relative_to(resolved, excluded) for excluded in excluded_roots):
            continue
        files.append(path.relative_to(source_root))
    return files


def plan_library(rel_paths: list[Path], include_podcasts: bool) -> Plan:
    destinations: list[Destination] = []
    skips: list[Skip] = []

    for rel_path in rel_paths:
        decision = target_for_path(rel_path, include_podcasts)
        if isinstance(decision, Destination):
            destinations.append(decision)
        else:
            skips.append(decision)

    destinations, warnings = uniquify_destinations(destinations)
    return Plan(
        discovered=len(rel_paths),
        destinations=destinations,
        skips=skips,
        warnings=warnings,
    )


def uniquify_destinations(destinations: list[Destination]) -> tuple[list[Destination], list[str]]:
    seen: dict[Path, int] = {}
    result: list[Destination] = []
    warnings: list[str] = []

    for item in destinations:
        target = item.target
        if target not in seen:
            seen[target] = 1
            result.append(item)
            continue

        if item.reason == "cover art" and target.stem == "folder":
            target = target.parent / "Artwork" / (sanitize_component(item.source.stem) + target.suffix)
            if target not in seen:
                seen[target] = 1
                warnings.append(f"cover collision: {item.target} -> {target}")
                result.append(Destination(item.source, target, "additional artwork"))
                continue

        seen[target] += 1
        suffix = seen[target]
        new_target = target.with_name(f"{target.stem}_{suffix}{target.suffix}")
        while new_target in seen:
            suffix += 1
            new_target = target.with_name(f"{target.stem}_{suffix}{target.suffix}")
        seen[new_target] = 1
        warnings.append(f"collision: {target} -> {new_target}")
        result.append(Destination(item.source, new_target, item.reason))

    return result, warnings


def write_report(path: Path, destinations: list[Destination], skips: list[Skip]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["action", "source", "target", "reason"])
        for item in destinations:
            writer.writerow(["move", item.source, item.target, item.reason])
        for item in skips:
            writer.writerow(["skip", item.source, "", item.reason])


def move_files(source_root: Path, dest_root: Path, destinations: list[Destination], overwrite: bool) -> tuple[int, int]:
    moved = 0
    unchanged = 0

    for item in destinations:
        source = source_root / item.source
        target = dest_root / item.target

        if source.resolve() == target.resolve():
            unchanged += 1
            continue

        if not source.exists():
            raise FileNotFoundError(f"Missing source: {source}")
        if target.exists():
            if not overwrite:
                raise FileExistsError(f"Destination already exists: {target}")
            target.unlink()
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(source), str(target))
        moved += 1

    return moved, unchanged


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Organize music files for Jellyfin.")
    parser.add_argument("--source-root", type=Path, default=Path("."), help="Messy music root to scan. Default: current directory.")
    parser.add_argument(
        "--dest-root",
        type=Path,
        default=None,
        help="Destination Jellyfin music root. Default: ./jellyfin-organized inside the source root.",
    )
    parser.add_argument("--report", type=Path, default=Path("music-organize-plan.csv"), help="CSV report path.")
    parser.add_argument("--include-podcasts", action="store_true", help="Include folders with Podcast in the name.")
    parser.add_argument("--apply", action="store_true", help="Actually move files. Default is dry-run.")
    parser.add_argument("--overwrite", action="store_true", help="Overwrite existing destination files when applying.")
    parser.add_argument("--limit", type=int, default=0, help="Only process the first N discovered files, useful for testing.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    source_root = args.source_root.expanduser().resolve()
    dest_root = (args.dest_root.expanduser() if args.dest_root else source_root / "jellyfin-organized").resolve()
    report_path = args.report.expanduser().resolve()

    if not source_root.is_dir():
        raise SystemExit(f"Source root is not a directory: {source_root}")

    excluded_roots = []
    if dest_root != source_root and is_relative_to(dest_root, source_root):
        excluded_roots.append(dest_root)
    excluded_files = [report_path] if is_relative_to(report_path, source_root) else []

    rel_paths = iter_source_files(source_root, excluded_roots, excluded_files)
    if args.limit:
        rel_paths = rel_paths[: args.limit]

    plan = plan_library(rel_paths, args.include_podcasts)
    write_report(report_path, plan.destinations, plan.skips)

    print(f"Scanned: {source_root}")
    print(f"Destination: {dest_root}")
    print(f"Discovered files: {plan.discovered}")
    print(f"Planned moves: {len(plan.destinations)}")
    print(f"Skipped: {len(plan.skips)}")
    print(f"Collision renames: {len(plan.warnings)}")
    print(f"Report: {report_path}")

    for item in plan.destinations[:20]:
        print(f"{item.source} -> {item.target}")
    if len(plan.destinations) > 20:
        print(f"... {len(plan.destinations) - 20} more planned moves")

    if plan.warnings:
        print("Warnings:")
        for warning in plan.warnings[:10]:
            print(f"  {warning}")
        if len(plan.warnings) > 10:
            print(f"  ... {len(plan.warnings) - 10} more warnings")

    if not args.apply:
        print("Dry run only. Re-run with --apply to move files.")
        return 0

    moved, unchanged = move_files(source_root, dest_root, plan.destinations, args.overwrite)
    print(f"Moved files: {moved}")
    print(f"Already in place: {unchanged}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
