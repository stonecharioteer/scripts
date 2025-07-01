# scripts
Scripts to help automate small tasks

## `audiobook-split.sh`

Split audiobooks into smaller segments for easier listening or processing.

**Requirements:**
- `ffmpeg` for audio processing
- `gum` for prettier terminal output

**Usage:**
```bash
./audiobook-split.sh <audiobook_file> [segment_duration_in_seconds]
./audiobook-split.sh -h  # Show help
```

**Supported formats:** m4a, m4b, mp3  
**Default segment duration:** 5 minutes (300 seconds)

**Examples:**
```bash
./audiobook-split.sh audiobook.m4a          # Split into 5-minute segments
./audiobook-split.sh audiobook.m4b 600      # Split into 10-minute segments
./audiobook-split.sh audiobook.mp3 480      # Split into 8-minute segments
```

Output files are saved in a directory named `{original_filename}_segments/` as numbered MP3 files.

## `gi-select.sh`

This script helps create a `.gitignore` from `github.com/github/gitignore`'s 
list of files.

First, clone the repo to `~/code/tools/gitignore`, then install `gum`.

Link this file as `gi-select` for convenience

![gi-select](./docs/gi-select.png)
