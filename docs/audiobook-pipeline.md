# Audiobook Pipeline

## Purpose

I needed a complete solution to manage audiobooks from Audible all the way to loading them into my Shokz OpenSwim headphones. This script provides an alternative to existing audiobook management tools by offering a complete pipeline that handles downloading, conversion, and splitting in one cohesive workflow.

## Overview

Modular audiobook processing pipeline with subcommands for different operations: download, convert, split, or full automation.

## Requirements

- `uvx` for running audible-cli
- `audible-cli` (automatically installed via uvx)
- `ffmpeg` (version 4.4+ for AAXC support)
- `gum` for interactive selection
- `audiobook-split.sh` (should be in same directory)

## Features

- **Modular design** - Separate subcommands for download, convert, split, and automate
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

## Setup

Before using this script, authenticate with Audible:
```bash
uvx --from audible-cli audible quickstart
```

## Usage

```bash
./audiobook-pipeline.sh <subcommand> [OPTIONS]
./audiobook-pipeline.sh -h  # Show help
```

## Subcommands

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
Convert existing AAX/AAXC files to M4B format (no download needed).

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
./audiobook-pipeline.sh convert ~/Downloads/*.aaxc                  # Convert multiple files
```

### Split Subcommand
Split M4B files into MP3 segments using audiobook-split.sh.

```bash
./audiobook-pipeline.sh split [OPTIONS] [input_file...]
```

**Options:**
- `-d, --duration SECONDS` - Segment duration in seconds (default: 300 = 5 minutes)
- `-o, --output-dir DIR` - Output directory (default: ~/Audiobooks/OpenSwim)
- `-n, --dry-run` - Show what would be processed without doing it

**Examples:**
```bash
./audiobook-pipeline.sh split                        # Split all M4B files in converted directory
./audiobook-pipeline.sh split book.m4b               # Split specific file
./audiobook-pipeline.sh split --duration 480         # 8-minute segments
./audiobook-pipeline.sh split --dry-run              # Preview what would happen
```

### Automate Subcommand
Full pipeline: download, convert, and split audiobooks in one step (original behavior).

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

## Global Options

- `-p, --profile PROFILE` - Audible profile to use
- `-d, --duration SECONDS` - Segment duration in seconds (default: 300 = 5 minutes)
- `-o, --output-dir DIR` - Output directory (default: ~/Audiobooks/OpenSwim)
- `-t, --temp-dir DIR` - Temporary download directory (default: ~/Audiobooks/audible)
- `-r, --raw-dir DIR` - Raw download directory (default: ~/Audiobooks/audible/raw)
- `-c, --converted-dir DIR` - Converted files directory (default: ~/Audiobooks/audible/converted)
- `-k, --keep-intermediate` - Keep intermediate files (M4B, AAX)
- `-n, --dry-run` - Show what would be processed without doing it

## Performance Optimization

- **Intelligent threading** - Auto-detects CPU architecture (AMD Ryzen, Intel Xeon, ARM)
- **Memory-aware** - Adjusts thread count based on available RAM
- **Performance logging** - Shows thread count, CPU model, and memory info
- **Optimized ffmpeg** - Uses efficient flags and threading for conversion

## Activation Bytes

- **Auto-retrieval** - Automatically gets activation bytes from audible-cli
- **AAX files** - Require activation bytes for decryption
- **AAXC files** - Don't need activation bytes (newer format)
- **Manual override** - Use `--activation-bytes` if needed

## Directory Structure

```
~/Audiobooks/audible/raw/        (original AAX/AAXC files)
~/Audiobooks/audible/converted/  (M4B files with chapters)
~/Audiobooks/OpenSwim/           (final MP3 files)
└── BookTitle/                   (one folder per book)
    ├── booktitle_01.mp3
    ├── booktitle_02.mp3
    └── ...
```

## Workflow Examples

### Download and Convert Only
```bash
# Download and convert to M4B (no splitting)
./audiobook-pipeline.sh download --all
```

### Convert Existing Files
```bash
# Convert existing AAX/AAXC files to M4B
./audiobook-pipeline.sh convert ~/Downloads/*.aax*
```

### Split Existing M4B Files
```bash
# Split M4B files into MP3 segments
./audiobook-pipeline.sh split --duration 600  # 10-minute segments
```

### Full Pipeline
```bash
# Complete pipeline: download → convert → split
./audiobook-pipeline.sh automate --duration 480
```

## Troubleshooting

### Common Issues

1. **Authentication errors**: Run `uvx --from audible-cli audible quickstart` to re-authenticate
2. **FFmpeg not found**: Install ffmpeg 4.4+ for AAXC support
3. **Activation bytes issues**: Use `--activation-bytes` flag or ensure audible-cli authentication is working
4. **Permission errors**: Check directory permissions for output locations

### Debug Options

- Use `--dry-run` to preview operations without executing
- Check audible-cli authentication: `uvx --from audible-cli audible library list`
- Verify ffmpeg installation: `ffmpeg -version`