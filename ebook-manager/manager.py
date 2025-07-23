#!/usr/bin/env python3
import argparse
import hashlib
import os
import sqlite3
import sys
from pathlib import Path
from collections import Counter

EXTS_DEFAULT = ".epub,.pdf,.mobi,.azw,.azw3"

VERBOSE = False


def vlog(*a, **k):
    if VERBOSE:
        print(*a, **k)


# ---------------- DB ----------------
def init_db(db_path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.executescript("""
    CREATE TABLE IF NOT EXISTS files(
      path  TEXT PRIMARY KEY,
      hash  TEXT NOT NULL,
      size  INTEGER NOT NULL,
      mtime REAL  NOT NULL,
      ext   TEXT  NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_hash ON files(hash);
    """)
    return conn


# -------------- HASHING -------------
def sha256(fp: Path, buf=1024 * 1024) -> str:
    h = hashlib.sha256()
    with fp.open("rb") as f:
        while chunk := f.read(buf):
            h.update(chunk)
    return h.hexdigest()


# -------------- SYNC ----------------
def cmd_sync(args):
    root = Path(args.root).resolve()
    exts = {e.strip().lower() for e in args.exts.split(",") if e.strip()}
    conn = init_db(Path(args.db))

    seen_paths: set[str] = set()
    present_hashes: set[str] = set()

    def upsert_and_track(p: Path):
        try:
            st = p.stat()
        except FileNotFoundError:
            vlog("SKIP vanished(stat)", p)
            return
        size, mtime, ext = st.st_size, st.st_mtime, p.suffix.lower()
        seen_paths.add(str(p))
        cur = conn.execute(
            "SELECT hash FROM files WHERE path=? AND size=? AND mtime=?",
            (str(p), size, mtime),
        )
        row = cur.fetchone()
        if row:
            h = row[0]
            present_hashes.add(h)
            vlog("CACHED", p)
            return
        try:
            h = sha256(p)
        except FileNotFoundError:
            vlog("SKIP vanished(read)", p)
            return
        present_hashes.add(h)
        conn.execute(
            """INSERT INTO files(path,hash,size,mtime,ext)
                        VALUES(?,?,?,?,?)
                        ON CONFLICT(path) DO UPDATE SET
                          hash=excluded.hash,
                          size=excluded.size,
                          mtime=excluded.mtime,
                          ext=excluded.ext""",
            (str(p), h, size, mtime, ext),
        )
        vlog("HASHED", p)

    for r, _, files in os.walk(root):
        for f in files:
            p = Path(r) / f
            if p.suffix.lower() in exts:
                upsert_and_track(p)

    # handle vanished DB entries
    stale = conn.execute("SELECT path, hash FROM files").fetchall()

    missing = []  # missing & unique hash
    removed_moved = 0
    removed_missing = 0

    for path_str, h in stale:
        if path_str in seen_paths:
            continue
        if Path(path_str).exists():
            continue  # exists but skipped for some reason

        # same hash elsewhere (and exists)?
        rows_same_hash = conn.execute(
            "SELECT path FROM files WHERE hash=? AND path<>?", (h, path_str)
        ).fetchall()
        moved_elsewhere = any(Path(op).exists() for (op,) in rows_same_hash)

        if moved_elsewhere:
            conn.execute("DELETE FROM files WHERE path=?", (path_str,))
            removed_moved += 1
            vlog("REMOVED_MOVED", path_str)
        else:
            if args.clean:
                conn.execute("DELETE FROM files WHERE path=?", (path_str,))
                removed_missing += 1
                vlog("REMOVED_MISSING", path_str)
            else:
                missing.append(path_str)

    conn.commit()
    conn.close()

    if missing:
        print("WARN: Missing files not found elsewhere:")
        for p in missing:
            print("  ", p)

    print(
        f"Summary: moved={removed_moved}, missing_removed={removed_missing}, missing_warned={len(missing)}"
    )


# -------------- DEDUP ---------------
def cmd_dedup(args):
    token = args.unorganized
    conn = init_db(Path(args.db))

    rows = conn.execute(
        """
        WITH outside AS (
          SELECT DISTINCT hash FROM files WHERE instr(path, ?) = 0
        )
        SELECT path FROM files
        WHERE instr(path, ?) > 0
          AND hash IN (SELECT hash FROM outside)
    """,
        (token, token),
    ).fetchall()

    to_delete = [Path(r[0]) for r in rows]
    n = len(to_delete)
    if n == 0:
        print("Nothing to delete.")
        return

    if args.dry_run:
        print(f"Would delete {n} file(s):")
        for p in to_delete:
            print("  ", p)
        return

    deleted = 0
    for p in to_delete:
        try:
            p.unlink()
            conn.execute("DELETE FROM files WHERE path=?", (str(p),))
            deleted += 1
            vlog("DELETED", p)
        except Exception as e:
            print("ERROR  ", p, e, file=sys.stderr)

    conn.commit()
    conn.close()
    print(f"Deleted {deleted} of {n} file(s).")


# ------------- SUMMARY --------------
def cmd_summary(args):
    conn = init_db(Path(args.db))
    rows = conn.execute("SELECT path FROM files").fetchall()
    conn.close()

    if not rows:
        print("DB empty. Run `sync` first.")
        return

    paths = [Path(p).resolve() for (p,) in rows]
    lib_root = Path(os.path.commonpath([str(p) for p in paths]))

    counts = Counter()
    for p in paths:
        try:
            rel = p.relative_to(lib_root)
        except ValueError:
            rel = p
        first = rel.parts[0] if rel.parts else "."
        counts[first] += 1

    width = max(len(k) for k in counts) if counts else 4
    print(f"{'Subfolder':<{width}}  {'Files':>7}")
    print("-" * (width + 10))
    total = 0
    for k in sorted(counts):
        c = counts[k]
        total += c
        print(f"{k:<{width}}  {c:7d}")
    print("-" * (width + 10))
    print(f"{'TOTAL':<{width}}  {total:7d}")


# -------------- MAIN ----------------
def main():
    ap = argparse.ArgumentParser(prog="ebooks")
    ap.add_argument(
        "--db", default=str(Path.home() / ".ebook_hashes.sqlite"), help="SQLite DB path"
    )
    ap.add_argument(
        "--exts",
        default=EXTS_DEFAULT,
        help=f"Comma-separated extensions (default: {EXTS_DEFAULT})",
    )
    ap.add_argument(
        "-v", "--verbose", action="store_true", help="print per-file actions"
    )

    sub = ap.add_subparsers(dest="cmd", required=True)

    sp_sync = sub.add_parser("sync", help="scan & cache hashes")
    sp_sync.add_argument("root", help="Root directory to scan")
    sp_sync.add_argument(
        "--clean",
        action="store_true",
        help="remove missing entries from DB (that aren't moved)",
    )
    sp_sync.set_defaults(func=cmd_sync)

    sp_dedup = sub.add_parser(
        "dedup", help="delete dup files from the Unorganized folder"
    )
    sp_dedup.add_argument(
        "--unorganized",
        default="Unorganized",
        help="Folder name token to treat as unorganized (default: Unorganized)",
    )
    sp_dedup.add_argument(
        "--dry-run", action="store_true", help="Only show what would be deleted"
    )
    sp_dedup.set_defaults(func=cmd_dedup)

    sp_sum = sub.add_parser("summary", help="files per immediate subfolder (from DB)")
    sp_sum.set_defaults(func=cmd_summary)

    args = ap.parse_args()
    global VERBOSE
    VERBOSE = args.verbose
    args.func(args)


if __name__ == "__main__":
    main()
