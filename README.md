# scripts
Scripts to help automate small tasks

## `audiobook-split.sh`

Split audiobooks into smaller segments for easier listening or processing using ffmpeg's efficient segment muxer.

**Requirements:**
- `ffmpeg` for audio processing
- `gum` for prettier terminal output

**Features:**
- **Efficient processing** - Uses ffmpeg's built-in segment muxer (low memory usage)
- **Real-time progress** - Shows percentage, elapsed time, and ETA with fallback for older gum versions
- **Intelligent performance** - Auto-detects CPU architecture and optimizes thread count accordingly
- **FAT32-compatible filenames** - Lowercase, no special characters, shorter paths
- **Dynamic numbering** - Uses minimum digits needed (2-4 digits based on segment count)
- **Human-friendly indexing** - Starts from 1 instead of 0
- **Custom output directory** - Specify where files are saved, uses directory name as file prefix
- **Multiple formats** - Supports m4a, m4b, and mp3 input
- **Comprehensive analysis** - Post-processing summary with file statistics and anomaly detection

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
./audiobook-split.sh audiobook.mp3 480 -O harry_potter # Custom output directory
```

**Output:**
- Files saved as `{prefix}_01.mp3`, `{prefix}_02.mp3`, etc. (dynamic digit count)
- FAT32-compatible filenames (lowercase, underscores replace special chars)
- Custom directory: Uses directory name as prefix (e.g., `harry_potter_01.mp3`)
- Progress display: `🔄 45% (02:15 / 17:18:34) | Elapsed: 01:30 | ETA: 02:15`
- Performance info: `⚡ Performance: Using 16/32 threads (AMD Ryzen 9 7950X) | RAM: 64G`
- Post-processing analysis with file statistics and outlier detection

## `gi-select.sh`

This script helps create a `.gitignore` from `github.com/github/gitignore`'s 
list of files.

First, clone the repo to `~/code/tools/gitignore`, then install `gum`.

Link this file as `gi-select` for convenience

![gi-select](./docs/gi-select.png)
