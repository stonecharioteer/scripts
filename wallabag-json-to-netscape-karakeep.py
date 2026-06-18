#!/usr/bin/env python3
import sys
import json
import os
import html


def main():
    if len(sys.argv) < 2:
        print("Usage: python convert-wallabag-json-to-karakeep.py file.json")
        sys.exit(1)

    infile = sys.argv[1]
    if not os.path.exists(infile):
        print(f"File not found: {infile}")
        sys.exit(1)

    # Output filename
    base, _ = os.path.splitext(infile)
    outfile = base + ".html"

    # Load JSON
    with open(infile, "r", encoding="utf-8") as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError as e:
            print(f"Invalid JSON: {e}")
            sys.exit(1)

    # Wallabag JSON structure differs depending on export,
    # but usually "entries" is the key.
    entries = []
    if isinstance(data, dict) and "entries" in data:
        entries = data["entries"]
    elif isinstance(data, list):
        entries = data
    else:
        print("Unrecognized Wallabag JSON structure")
        sys.exit(1)

    # Start bookmarks HTML
    lines = []
    lines.append("<!DOCTYPE NETSCAPE-Bookmark-file-1>")
    lines.append('<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">')
    lines.append("<TITLE>Bookmarks</TITLE>")
    lines.append("<H1>Bookmarks</H1>")
    lines.append("<DL><p>")

    for e in entries:
        url = e.get("url") or e.get("origin_url")
        title = e.get("title") or url
        if not url:
            continue

        # Escape HTML
        url = html.escape(url, quote=True)
        title = html.escape(title)

        # Optional: add timestamp
        add_date = str(e.get("created_at", ""))

        lines.append(f'  <DT><A HREF="{url}" ADD_DATE="{add_date}">{title}</A>')

    lines.append("</DL><p>")

    with open(outfile, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    print(f"Converted {len(entries)} entries to {outfile}")


if __name__ == "__main__":
    main()
