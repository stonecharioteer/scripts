# scripts
Scripts to help automate small tasks

## `audiobook-split.sh`

Split audiobooks into smaller segments for easier listening or processing using ffmpeg's efficient segment muxer.

**Requirements:**
- `ffmpeg` for audio processing
- `gum` for prettier terminal output

**Features:**
- **Efficient processing** - Uses ffmpeg's built-in segment muxer (low memory usage)
- **Real-time progress** - Shows percentage, elapsed time, and ETA
- **FAT32-compatible filenames** - Lowercase, no special characters
- **4-digit numbering** - Zero-padded segments (0001-9999) for proper sorting
- **Custom output directory** - Specify where files are saved
- **Multiple formats** - Supports m4a, m4b, and mp3 input

**Usage:**
```bash
./audiobook-split.sh <audiobook_file> [segment_duration_in_seconds] [options]
./audiobook-split.sh -h  # Show help
```

**Options:**
- `-O, --output-dir DIR` - Custom output directory
- `-h, --help` - Show help message

**Supported formats:** m4a, m4b, mp3  
**Default segment duration:** 5 minutes (300 seconds)

**Examples:**
```bash
./audiobook-split.sh audiobook.m4a                    # Split into 5-minute segments
./audiobook-split.sh audiobook.m4b 600                # Split into 10-minute segments
./audiobook-split.sh audiobook.mp3 480 -O /media/usb  # Custom output directory
```

**Output:**
- Files saved as `{sanitized_filename}_segment_0001.mp3`, `0002.mp3`, etc.
- FAT32-compatible filenames (lowercase, underscores replace special chars)
- Progress display: `🔄 45% (02:15 / 17:18:34) | Elapsed: 01:30 | ETA: 02:15`

## `gi-select.sh`

This script helps create a `.gitignore` from `github.com/github/gitignore`'s 
list of files.

First, clone the repo to `~/code/tools/gitignore`, then install `gum`.

Link this file as `gi-select` for convenience

![gi-select](./docs/gi-select.png)
