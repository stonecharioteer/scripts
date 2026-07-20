# Jellyfin music organizer

`music_manage.py` turns a messy download dump into a Jellyfin-friendly tree:

```text
Artist/Album (Year)/01 - Track.ext
Artist/Album (Year)/Disc 01/01 - Track.ext
Artist/Album (Year)/folder.jpg
```

## Important limitations

- **Path/name heuristics only** — it does not read embedded tags (no mutagen/ffprobe).
- **Dry-run by default** — nothing moves or deletes until you opt in.
- **Not transactional** — a failed `--apply` mid-run can leave a partial library; use `--limit` to test.
- Sidecars like `.cue`, `.log`, `.nfo`, `.mkv`, `.pdf` are skipped as junk by default.

## Quick start

```bash
# From the messy music directory (or pass --source-root)
python3 path/to/scripts/homelab/jellyfin/music_manage.py

# Inspect the plan
less music-organize-plan.csv   # written under --source-root by default

# Apply moves only
python3 path/to/scripts/homelab/jellyfin/music_manage.py --apply

# Apply moves and permanently delete exact duplicate sources
python3 path/to/scripts/homelab/jellyfin/music_manage.py --apply --delete-duplicates
```

## Flags

| Flag | Default | Meaning |
|------|---------|---------|
| `--source-root` | `.` | Messy library root to scan |
| `--dest-root` | `<source>/jellyfin-organized` | Destination tree |
| `--report` | `<source>/music-organize-plan.csv` | Full move/delete/skip plan |
| `--include-podcasts` | off | Include folders with “Podcast” in the name |
| `--apply` | off | Perform moves |
| `--delete-duplicates` | off | Permanently delete exact-duplicate sources (requires `--apply`) |
| `--overwrite` | off | Replace existing files at the destination |
| `--limit N` | `0` (all) | Only plan/apply the first N discovered files |

## Safety model

1. **Plan** always runs and writes the CSV (`move` / `delete` / `skip`).
2. **`--apply`** moves planned files only.
3. **`--delete-duplicates`** is required to unlink sources that SHA-256-match another file already planned for the same destination. Size is checked before hashing.
4. Non-identical collisions get a `_2`, `_3`, … suffix (or cover art is redirected under `Artwork/`).

## Tests

```bash
python3 -m unittest tests.test_music_manage -v
```
