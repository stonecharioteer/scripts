# scripts
Scripts to help automate small tasks

## Table of Contents

1. [audiobook-split.sh](#audiobook-splitsh) - Split audiobooks into smaller segments
2. [gi-select.sh](#gi-selectsh) - Interactive .gitignore file generator
3. [highlight-manager.sh](#highlight-managersh) - Manage Kindle highlights with DuckDB

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

## `highlight-manager.sh`

Comprehensive Kindle highlights management system with DuckDB integration for storage, organization, and beautiful terminal display.

**Requirements:**
- `duckdb` for database storage
- `gum` for terminal UI styling
- `jq` for JSON processing
- `python3` for data transformation

**Features:**
- **Database storage** - Robust DuckDB backend with proper schema and indexing
- **Import system** - Processes myClippings.txt with duplicate detection and content normalization
- **Beautiful display** - Elegant terminal interface with text wrapping and proper spacing
- **Flexible sorting** - Sort by location or date_added with ascending/descending order
- **Smart UI behavior** - Only prompts for full highlights view when using default count
- **Book/author separation** - Parses "Title (Author)" format into separate database fields
- **Content processing** - Removes trailing spaces, em-dashes, normalizes whitespace
- **Duplicate prevention** - SHA256 content hashing prevents duplicate imports
- **Configurable options** - Custom database path, variable highlight count display
- **Text wrapping** - Adaptive width detection (screen width vs 80 chars, whichever smaller)

**Usage:**
```bash
./highlight-manager.sh <subcommand> [options]
./highlight-manager.sh -h  # Show help
```

**Subcommands:**
- `import` - Import highlights from myClippings file to database
- `show` - Display highlights from database with beautiful formatting

**Global Options:**
- `--database-path PATH` - Database file path (default: ~/Documents/highlights.db)
- `-h, --help` - Show help message

**Import Options:**
- `INPUT_FILE` - myClippings file to import (default: myClippings.txt)

**Show Options:**
- `-n, --number COUNT` - Number of highlights to show (default: 10)
- `--sort-by FIELD` - Sort by field: location, date_added (default: location)
- `--sort-order ORDER` - Sort order: asc, desc (default: asc)

**Examples:**
```bash
./highlight-manager.sh import myClippings.txt                    # Import highlights
./highlight-manager.sh show -n 5                               # Show 5 highlights (no prompt for full view)
./highlight-manager.sh show --sort-by date_added               # Sort by date added (ascending)
./highlight-manager.sh show --sort-by location --sort-order desc # Sort by location (descending)
./highlight-manager.sh --database-path ~/custom.db import      # Custom database location
./highlight-manager.sh show --number 20 --sort-by date_added   # Show 20 highlights sorted by date
```

**Display Format:**
```
1. Empire of AI by Karen Hao

   Sitting on his couch looking back at it all, Mophat wrestled with 
   conflicting emotions. "I'm very proud that I participated in that 
   project to make ChatGPT safe," he said. "But now the question I always 
   ask myself: Was my input worth what I received in return?"

   📍 page 351
   📅 Sunday, July 06, 2025 12:52:01 PM
```

**Database Schema:**
- `book_title` - Book title (extracted from "Title (Author)" format)
- `author` - Author name (extracted from parentheses)
- `highlight_type` - Type of highlight (highlight, note, bookmark)
- `location` - Page number or location reference
- `date_added` - Timestamp when highlight was created
- `content` - Full highlight text (cleaned and normalized)
- `content_hash` - SHA256 hash for duplicate detection
- `created_at` - Import timestamp
