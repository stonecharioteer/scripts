# scripts
Scripts to help automate small tasks

## Table of Contents

1. [audiobook-pipeline.sh](#audiobook-pipelinesh) - Complete audiobook processing pipeline
2. [audiobook-split.sh](#audiobook-splitsh) - Split audiobooks into smaller segments
3. [audible-download.sh](#audible-downloadsh) - Download audiobooks from Audible
4. [gi-select.sh](#gi-selectsh) - Interactive .gitignore file generator
5. [highlight-manager.sh](#highlight-managersh) - Manage Kindle highlights with DuckDB
6. [power-monitor](#power-monitor) - House and room-level power monitoring system

## `audiobook-pipeline.sh`

I needed a complete solution to manage audiobooks from Audible all the way to loading them into my Shokz OpenSwim headphones. This script provides an alternative to existing audiobook management tools by offering a complete pipeline that handles downloading, conversion, and splitting in one cohesive workflow.

Modular audiobook processing pipeline with subcommands for different operations: download, convert, or full automation.

**Requirements:**
- `uvx` for running audible-cli
- `audible-cli` (automatically installed via uvx)
- `ffmpeg` (version 4.4+ for AAXC support)
- `gum` for interactive selection
- `audiobook-split.sh` (should be in same directory)

**Features:**
- **Modular design** - Separate subcommands for download, convert, and automate
- **Automatic M4B conversion** - Downloads automatically convert to M4B with chapter preservation
- **Organized directory structure** - Separates raw downloads, converted files, and final output
- **CPU optimization** - Intelligent thread detection and performance optimization like audiobook-split.sh
- **Interactive selection** - Use gum to choose specific audiobooks from your library
- **Format conversion** - AAX/AAXC to M4B to MP3 with automatic activation bytes retrieval
- **Chapter preservation** - Maintains chapter information and metadata during conversion
- **Multiple file support** - Convert multiple existing files in one command
- **Progress tracking** - Real-time progress with performance info for each step
- **Dry-run mode** - Preview what would be processed without doing it
- **Intermediate file management** - Option to keep or clean up temporary files
- **Profile support** - Use different Audible accounts/profiles

**Setup:**
Before using this script, authenticate with Audible:
```bash
uvx --from audible-cli audible quickstart
```

**Usage:**
```bash
./audiobook-pipeline.sh <subcommand> [OPTIONS]
./audiobook-pipeline.sh -h  # Show help
```

**Subcommands:**

### Download Subcommand
Download audiobooks from your Audible library with automatic conversion to M4B.

```bash
./audiobook-pipeline.sh download [OPTIONS]
```

**Options:**
- `-a, --all` - Download all audiobooks from library
- `-f, --format FORMAT` - Download format: aaxc, aax, pdf (default: aaxc)
- `--activation-bytes BYTES` - Activation bytes (auto-retrieved if not provided)
- `--no-convert` - Skip automatic conversion to M4B

**Examples:**
```bash
./audiobook-pipeline.sh download                    # Interactive selection with auto-conversion
./audiobook-pipeline.sh download --all              # Download all audiobooks with conversion
./audiobook-pipeline.sh download --format aax       # Download in AAX format with conversion
./audiobook-pipeline.sh download --no-convert       # Download only, no conversion
./audiobook-pipeline.sh download --all --profile work  # Use specific profile
```

### Convert Subcommand
Convert existing AAX/AAXC files to split MP3 segments (no download needed).

```bash
./audiobook-pipeline.sh convert [OPTIONS] <input_file> [input_file2...]
```

**Options:**
- `--activation-bytes BYTES` - Activation bytes (auto-retrieved if not provided)
- `--title TITLE` - Override book title (default: extracted from file metadata)

**Examples:**
```bash
./audiobook-pipeline.sh convert book.aaxc                           # Convert single file
./audiobook-pipeline.sh convert *.aaxc                              # Convert multiple files
./audiobook-pipeline.sh convert book.aax --title "My Book"          # Custom title
./audiobook-pipeline.sh convert book.aax --duration 480             # 8-minute segments
./audiobook-pipeline.sh convert ~/Downloads/*.aaxc --keep-intermediate  # Keep M4B files
```

### Automate Subcommand
Full pipeline: download and convert audiobooks in one step (original behavior).

```bash
./audiobook-pipeline.sh automate [OPTIONS]
```

**Examples:**
```bash
./audiobook-pipeline.sh automate                    # Full interactive pipeline
./audiobook-pipeline.sh automate --profile work     # Use specific profile
./audiobook-pipeline.sh automate --duration 480     # 8-minute segments
./audiobook-pipeline.sh automate --dry-run          # Preview what would happen
```

**Global Options:**
- `-p, --profile PROFILE` - Audible profile to use
- `-d, --duration SECONDS` - Segment duration in seconds (default: 300 = 5 minutes)
- `-o, --output-dir DIR` - Output directory (default: ~/Audiobooks/OpenSwim)
- `-t, --temp-dir DIR` - Temporary download directory (default: ~/Audiobooks/audible)
- `-r, --raw-dir DIR` - Raw download directory (default: ~/Audiobooks/audible/raw)
- `-c, --converted-dir DIR` - Converted files directory (default: ~/Audiobooks/audible/converted)
- `-k, --keep-intermediate` - Keep intermediate files (M4B, AAX)
- `-n, --dry-run` - Show what would be processed without doing it

**Performance Optimization:**
- **Intelligent threading** - Auto-detects CPU architecture (AMD Ryzen, Intel Xeon, ARM)
- **Memory-aware** - Adjusts thread count based on available RAM
- **Performance logging** - Shows thread count, CPU model, and memory info
- **Optimized ffmpeg** - Uses efficient flags and threading for conversion

**Activation Bytes:**
- **Auto-retrieval** - Automatically gets activation bytes from audible-cli
- **AAX files** - Require activation bytes for decryption
- **AAXC files** - Don't need activation bytes (newer format)
- **Manual override** - Use `--activation-bytes` if needed

**Directory Structure:**
```
~/Audiobooks/audible/raw/        (original AAX/AAXC files)
~/Audiobooks/audible/converted/  (M4B files with chapters)
~/Audiobooks/OpenSwim/           (final MP3 files)
└── BookTitle/                   (one folder per book)
    ├── booktitle_01.mp3
    ├── booktitle_02.mp3
    └── ...
```

## `audiobook-split.sh`

I needed to split audiobooks into smaller segments specifically for compatibility with my Shokz OpenSwim headphones, which work better with shorter audio files during swimming workouts.

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

## `audible-download.sh`

The audible-cli tool isn't trivial to use for bulk operations, so I needed a wrapper script to simplify downloading all my books from Audible with better configuration options and user experience.

Download audiobooks from Audible using audible-cli with comprehensive configuration options.

**Requirements:**
- `uvx` for running audible-cli
- `audible-cli` (installed via uvx)
- `gum` for prettier terminal output (optional)

**Features:**
- **Multiple download formats** - AAXC, AAX, and PDF support
- **Flexible filtering** - Download by date range or all audiobooks
- **Profile support** - Use different Audible accounts/profiles
- **Dry-run mode** - Preview what would be downloaded without downloading
- **Custom output directory** - Specify download location (default: ~/Audiobooks/audible)
- **Progress tracking** - Real-time download progress with verbose levels
- **Input validation** - Validates dates, formats, and dependencies
- **Enhanced UI** - Styled output with gum integration

**Setup:**
Before using this script, authenticate with Audible:
```bash
uvx --from audible-cli audible quickstart
```

**Usage:**
```bash
./audible-download.sh [OPTIONS]
./audible-download.sh -h  # Show help
```

**Options:**
- `-d, --download-dir DIR` - Download directory (default: ~/Audiobooks/audible)
- `-p, --profile PROFILE` - Audible profile to use
- `-f, --format FORMAT` - Download format: aaxc, aax, pdf (default: aaxc)
- `-a, --all` - Download all audiobooks from library
- `-s, --start-date DATE` - Download books added after this date (YYYY-MM-DD)
- `-e, --end-date DATE` - Download books added before this date (YYYY-MM-DD)
- `-v, --verbose LEVEL` - Verbose level: debug, info, warning, error (default: info)
- `-n, --dry-run` - Show what would be downloaded without downloading

**Examples:**
```bash
./audible-download.sh --all                              # Download all audiobooks
./audible-download.sh --all --format aax                 # Download all as AAX format
./audible-download.sh --start-date "2023-01-01" --all    # Download books added after Jan 1, 2023
./audible-download.sh --profile work --all               # Use specific profile
./audible-download.sh --dry-run --all                    # Preview what would be downloaded
```

## `gi-select.sh`

I needed a more usable way to maintain gitignore files across different projects, with plans to enhance this further in the future.

This script helps create a `.gitignore` from `github.com/github/gitignore`'s 
list of files.

First, clone the repo to `~/code/tools/gitignore`, then install `gum`.

Link this file as `gi-select` for convenience

![gi-select](./docs/gi-select.png)

## `highlight-manager.sh`

I read on multiple digital devices and use KOReader everywhere, but it doesn't sync highlights well across devices. I don't want to use the kohighlights plugin for Calibre because that would require using Calibre to maintain the library on all devices. Instead, I export highlights in myClippings.txt format from each device and use this script to consolidate them all in one place.

Comprehensive Kindle highlights management system with DuckDB integration for storage, organization, and beautiful terminal display.

**Requirements:**
- `duckdb` for database storage
- `gum` for terminal UI styling
- `jq` for JSON processing
- `python3` for data transformation

**Features:**
- **Database storage** - Robust DuckDB backend with proper schema and indexing
- **Multiple file import** - Process multiple myClippings files in a single command with wildcard support
- **Enhanced duplicate detection** - SHA256 content hashing with clean import summaries (no error spam)
- **Database statistics** - Comprehensive summary showing books, authors, highlight counts, and date ranges
- **Beautiful display** - Elegant terminal interface with text wrapping and proper spacing
- **Flexible sorting** - Sort by location or date_added with ascending/descending order
- **Smart UI behavior** - Only prompts for full highlights view when using default count
- **Book/author separation** - Parses "Title (Author)" format into separate database fields
- **Content processing** - Removes trailing spaces, em-dashes, normalizes whitespace
- **Overall import tracking** - Shows cumulative statistics across multiple files
- **Configurable options** - Custom database path, variable highlight count display
- **Text wrapping** - Adaptive width detection (screen width vs 80 chars, whichever smaller)

**Usage:**
```bash
./highlight-manager.sh <subcommand> [options]
./highlight-manager.sh -h  # Show help
```

**Subcommands:**
- `import` - Import highlights from myClippings file(s) to database
- `show` - Display highlights from database with beautiful formatting
- `summary` - Show database statistics and overview

**Global Options:**
- `--database-path PATH` - Database file path (default: ~/Documents/highlights.db)
- `-h, --help` - Show help message

**Import Options:**
- `INPUT_FILE...` - One or more myClippings files to import (default: myClippings.txt)
- Supports wildcards: `*.clippings.txt`, `book*.txt`, etc.

**Show Options:**
- `-n, --number COUNT` - Number of highlights to show (default: 10)
- `--sort-by FIELD` - Sort by field: location, date_added (default: location)
- `--sort-order ORDER` - Sort order: asc, desc (default: asc)

**Examples:**
```bash
# Import commands
./highlight-manager.sh import myClippings.txt                    # Import single file
./highlight-manager.sh import file1.txt file2.txt file3.txt     # Import multiple files
./highlight-manager.sh import *.clippings.txt                   # Import with wildcards
./highlight-manager.sh --database-path ~/custom.db import book*.txt # Custom database + multiple files

# Show commands
./highlight-manager.sh show -n 5                               # Show 5 highlights (no prompt for full view)
./highlight-manager.sh show --sort-by date_added               # Sort by date added (ascending)
./highlight-manager.sh show --sort-by location --sort-order desc # Sort by location (descending)
./highlight-manager.sh show --number 20 --sort-by date_added   # Show 20 highlights sorted by date

# Summary command
./highlight-manager.sh summary                                  # Show database overview
./highlight-manager.sh summary --database-path ~/custom.db     # Summary for custom database
```

**Import Output Format:**
```
✅ Import completed:
   - 127 quotes found in file
   - 126 new highlights imported
   - 1 duplicates skipped (already in database)
   - 130 total highlights in database

# Multiple file import adds overall summary:
📊 Overall Import Summary:
   - 131 total quotes found across all files
   - 126 new highlights imported
   - 5 duplicates skipped
   - 149 total highlights in database
```

**Summary Output Format:**
```
📊 Overall Statistics:
   Total highlights: 154
   Unique books: 3
   Unique authors: 3

📚 Highlights per Book:
   Empire of AI                           by Karen Hao            76 highlights
   In Spite of the Gods                   by Edward Luce          59 highlights
   MAHABHARATA: THE EPIC AND THE NATION   by Devy, G. N.          19 highlights

📅 Date Range:
   Earliest highlight: Friday, June 27, 2025 01:02:34 PM
   Latest highlight: Tuesday, June 24, 2025 08:31:37 PM

✍️  Top Authors by Highlight Count:
   Karen Hao                      76 highlights
   Edward Luce                    59 highlights
   Devy, G. N.                    19 highlights
```

**Show Display Format:**
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

## Power Monitor

I needed a reliable way to monitor my house power status and distinguish between normal operation, backup power operation, and critical system failures. This is especially important in a smart home setup with backup power systems where certain switches are connected to backup power and must always be online - if they go offline, it indicates the monitoring system itself may be at risk.

Comprehensive house and room-level power monitoring system that tracks smart switch connectivity to determine power states with backup-aware logic.

**Requirements:**
- `duckdb` for database operations
- `ping` for connectivity testing
- `arp` or `ip` for MAC address validation
- `jq` for JSON processing
- `gum` for beautiful UI (optional, falls back to text mode)

**Architecture:**
```
power-monitor/
├── power-monitor.sh           # Main script with subcommands
├── lib/                       # Modular library components
│   ├── database.sh           # DuckDB operations and abstractions
│   ├── network.sh            # Switch connectivity + MAC validation
│   ├── power-logic.sh        # Backup-aware power state calculations
│   ├── config.sh             # Configuration loading and validation
│   └── ui.sh                 # Gum UI components and color styling
├── config/
│   └── switches.json         # Switch definitions with backup-connected field
└── sql/
    ├── init.sql              # Database schema initialization
    └── queries.sql           # Common SQL queries
```

**Power States:**
- **ONLINE** (Green) - Main power available, all systems normal
- **BACKUP** (Yellow) - Running on backup power (main power lost)
- **CRITICAL** (Red) - Backup power failed, system at risk
- **OFFLINE** (Red) - No power detected anywhere

**Key Features:**
- **Backup-Aware Logic** - Distinguishes main power from backup power switches
- **Enhanced Network Detection** - Three-stage validation: ping → ARP table → ARP refresh with informative user messaging
- **MAC Address Validation** - Prevents false positives from IP conflicts using ARP table verification
- **Alternative Detection** - Detects devices that don't respond to ping but are reachable via ARP table
- **Room-Level Tracking** - Individual room power monitoring and uptime
- **Beautiful UI** - Color-coded status displays with gum styling (fallback to text mode)
- **Database Storage** - DuckDB for historical data with future migration path to Prometheus/InfluxDB
- **Critical Infrastructure Monitoring** - Special handling for backup-connected switches
- **Comprehensive Help** - Full help system for all subcommands
- **Modular Design** - Clean separation for easy testing and maintenance
- **Automation-Friendly** - Non-interactive mode with clean log messages for cron jobs

**Setup:**
```bash
# 1. Configure your switches
cp power-monitor/config/switches.json.example power-monitor/config/switches.json
# Edit switches.json with your actual switch IP addresses, MAC addresses, and locations

# 2. Initialize the system
./power-monitor/power-monitor.sh init

# 3. Test connectivity
./power-monitor/power-monitor.sh record

# 4. View status
./power-monitor/power-monitor.sh status
```

**Usage:**
```bash
# Initialize database and system
./power-monitor.sh init

# Record current power status (check all switches)
./power-monitor.sh record [--timeout SECONDS] [--verbose]

# Display current status with beautiful tables
./power-monitor.sh status [--room ROOM] [--verbose]

# Show uptime information
./power-monitor.sh uptime [--room ROOM] [--all-rooms]

# View outage history and analysis  
./power-monitor.sh history [--days N] [--room ROOM]

# Room management and statistics
./power-monitor.sh rooms [list|stats]

# Test system components
./power-monitor.sh test [config|network|database|power-logic|ui|all]

# Get help for any subcommand
./power-monitor.sh <subcommand> --help
```

**Switch Configuration (switches.json):**
```json
[
  {
    "label": "living-room-lamp",
    "ip-address": "192.168.1.100",
    "location": "living-room",
    "mac-address": "aa:bb:cc:dd:ee:01",
    "backup-connected": false
  },
  {
    "label": "server-switch",
    "ip-address": "192.168.1.102",
    "location": "server-room", 
    "mac-address": "aa:bb:cc:dd:ee:03",
    "backup-connected": true
  }
]
```

**Network Validation:**
- Three-stage validation: ping connectivity + ARP MAC address verification + ARP refresh fallback
- Enhanced ARP freshness validation to prevent false positives from stale cache entries
- Prevents false positives from IP conflicts or device replacements
- Alternative detection for devices that block ping but are reachable via ARP table
- Real-time progress feedback during network checks with device context (label, IP, room)
- Handles ARP cache misses and network timeouts gracefully
- Informative messages: `⚠ fridge (192.168.100.110, vinay-bedroom) not responding to ping, checking ARP table...`
- Success notifications: `✓ fridge detected via fresh ARP entry (ping failed but MAC verified)`
- Stale entry warnings: `⚠ fridge has stale ARP entry (treating as offline)`

**Detection Method Tracking:**
All device status checks are recorded with numeric detection method codes for analysis and debugging:

- **0 - FAILED**: Device failed all detection methods or has stale ARP entries (truly offline)
- **1 - PING_ONLY**: Ping successful, MAC validation skipped/failed  
- **2 - PING_MAC**: Ping successful + MAC validation successful (most reliable)
- **3 - ARP_FRESH**: Ping failed, detected via fresh ARP entry (REACHABLE/DELAY state)
- **4 - ARP_STALE**: DEPRECATED - stale entries now treated as FAILED (0)
- **5 - ARP_REFRESH**: Ping failed, detected after ARP cache refresh
- **6 - ARPING**: Ping failed, detected via arping probe (real-time validation)

Stale ARP entries are now treated as failures to prevent false positives during power outages. Only fresh ARP entries (REACHABLE/DELAY state) are considered valid alternative detections.

**Database Features:**
- Historical power status tracking with timestamps
- Room-level and house-level power statistics
- Outage detection and duration analysis
- Switch-level connectivity logs with response times
- Reliability statistics and uptime calculations
- Data export capabilities for external analysis

**Automation:**
```bash
# Add to crontab for regular monitoring (every 5 minutes)
*/5 * * * * /path/to/power-monitor.sh record >/dev/null 2>&1

# Daily status summary email
0 8 * * * /path/to/power-monitor.sh status | mail -s "Daily Power Status" admin@example.com
```

**Example Status Output:**
```
┌──────────────────────────────────────────────────┐
│                 Power Monitor                    │
│          House & Room Status [BACKUP]           │
└──────────────────────────────────────────────────┘

System Status: BACKUP (Main power lost 2h 15m ago)

┌─────────────┬──────────┬────────┬──────────────┬────────┐
│    Room     │ Switches │ Status │    Uptime    │ Backup │
├─────────────┼──────────┼────────┼──────────────┼────────┤
│ Living Room │   2/3    │PARTIAL │     --       │   No   │
│ Bedroom     │   2/2    │ ONLINE │  2d 15h 23m  │   No   │
│ Server Room │   1/1    │ ONLINE │  2d 15h 23m  │  Yes   │
└─────────────┴──────────┴────────┴──────────────┴────────┘

Critical Infrastructure: All backup systems operational
```

**Future Migration:**
The database layer is designed for easy migration to time-series databases like InfluxDB or Prometheus for integration with Grafana dashboards and alerting systems.

**Detailed Documentation:**
See `docs/power-monitor.readme.md` for comprehensive technical documentation, architecture details, and troubleshooting guides.
