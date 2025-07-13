# Audible Download

## Purpose

The audible-cli tool isn't trivial to use for bulk operations, so I needed a wrapper script to simplify downloading all my books from Audible with better configuration options and user experience.

## Overview

Download audiobooks from Audible using audible-cli with comprehensive configuration options.

## Requirements

- `uvx` for running audible-cli
- `audible-cli` (installed via uvx)
- `gum` for prettier terminal output (optional)

## Features

- **Multiple download formats** - AAXC, AAX, and PDF support
- **Flexible filtering** - Download by date range or all audiobooks
- **Profile support** - Use different Audible accounts/profiles
- **Dry-run mode** - Preview what would be downloaded without downloading
- **Custom output directory** - Specify download location (default: ~/Audiobooks/audible)
- **Progress tracking** - Real-time download progress with verbose levels
- **Input validation** - Validates dates, formats, and dependencies
- **Enhanced UI** - Styled output with gum integration

## Setup

Before using this script, authenticate with Audible:

```bash
uvx --from audible-cli audible quickstart
```

This will walk you through the authentication process and save your credentials for future use.

## Usage

```bash
./audible-download.sh [OPTIONS]
./audible-download.sh -h  # Show help
```

## Options

- `-d, --download-dir DIR` - Download directory (default: ~/Audiobooks/audible)
- `-p, --profile PROFILE` - Audible profile to use
- `-f, --format FORMAT` - Download format: aaxc, aax, pdf (default: aaxc)
- `-a, --all` - Download all audiobooks from library
- `-s, --start-date DATE` - Download books added after this date (YYYY-MM-DD)
- `-e, --end-date DATE` - Download books added before this date (YYYY-MM-DD)
- `-v, --verbose LEVEL` - Verbose level: debug, info, warning, error (default: info)
- `-n, --dry-run` - Show what would be downloaded without downloading

## Examples

### Download All Books

```bash
./audible-download.sh --all                              # Download all audiobooks
./audible-download.sh --all --format aax                 # Download all as AAX format
./audible-download.sh --all --dry-run                    # Preview what would be downloaded
```

### Date-Based Downloads

```bash
./audible-download.sh --start-date "2023-01-01" --all    # Download books added after Jan 1, 2023
./audible-download.sh --start-date "2023-01-01" --end-date "2023-12-31" --all  # Download from 2023 only
```

### Profile Management

```bash
./audible-download.sh --profile work --all               # Use specific profile
./audible-download.sh --profile personal --format aaxc   # Use personal account with AAXC format
```

### Custom Directory

```bash
./audible-download.sh --all --download-dir ~/MyBooks     # Download to custom directory
```

### Debug and Testing

```bash
./audible-download.sh --all --verbose debug              # Maximum verbosity
./audible-download.sh --all --dry-run --verbose info     # Preview with info logging
```

## Download Formats

### AAXC (Default)
- **Pros**: Newest format, no activation bytes needed, better compression
- **Cons**: Requires newer tools for conversion
- **Use case**: Recommended for new downloads

### AAX
- **Pros**: Widely supported, well-established format
- **Cons**: Requires activation bytes for conversion
- **Use case**: Good for compatibility with older tools

### PDF
- **Pros**: For books that include PDF content
- **Cons**: Not audio files
- **Use case**: Companion materials, illustrated books

## Profiles

Audible CLI supports multiple profiles for different accounts:

### Setup Profiles
```bash
# Set up additional profile
uvx --from audible-cli audible --profile work quickstart

# List available profiles
uvx --from audible-cli audible --profile work library list
```

### Using Profiles
```bash
./audible-download.sh --profile work --all
./audible-download.sh --profile personal --format aax
```

## Date Filtering

Use date ranges to download books acquired during specific periods:

### Format
- Date format: `YYYY-MM-DD`
- Start date: Books added on or after this date
- End date: Books added on or before this date

### Examples
```bash
# Books from last month
./audible-download.sh --start-date "2024-06-01" --end-date "2024-06-30" --all

# Books from this year
./audible-download.sh --start-date "2024-01-01" --all

# Books before a certain date
./audible-download.sh --end-date "2023-12-31" --all
```

## Verbose Levels

Control output detail with verbose levels:

- **error**: Only show errors
- **warning**: Show warnings and errors
- **info** (default): Show general information
- **debug**: Show detailed debugging information

### Examples
```bash
./audible-download.sh --all --verbose error    # Minimal output
./audible-download.sh --all --verbose debug    # Maximum detail
```

## Dry Run Mode

Preview operations without actually downloading:

```bash
./audible-download.sh --all --dry-run
```

This will:
- Show which books would be downloaded
- Display file sizes and formats
- Verify authentication and settings
- Not download any files

## Directory Structure

```
~/Audiobooks/audible/                # Default download directory
├── Book Title 1.aaxc
├── Book Title 2.aaxc
├── Book Title 3.aax
└── ...
```

Custom directory structure:
```
/custom/path/
├── downloaded books...
```

## Integration with Other Scripts

This script is designed to work with the audiobook pipeline:

### Manual Workflow
```bash
# 1. Download books
./audible-download.sh --all

# 2. Convert to M4B
./audiobook-pipeline.sh convert ~/Audiobooks/audible/*.aax*

# 3. Split into segments
./audiobook-pipeline.sh split
```

### Automated Workflow
```bash
# Use audiobook-pipeline for full automation
./audiobook-pipeline.sh automate
```

## Troubleshooting

### Authentication Issues

1. **Invalid credentials**: Run `uvx --from audible-cli audible quickstart` to re-authenticate
2. **Profile not found**: List profiles with `uvx --from audible-cli audible --profile PROFILE library list`
3. **Connection errors**: Check internet connection and Audible service status

### Download Issues

1. **No books found**: Verify library has books in specified date range
2. **Permission errors**: Check download directory permissions
3. **Disk space**: Ensure sufficient space (audiobooks can be large)
4. **Format not available**: Some books may not be available in all formats

### Dependencies

1. **uvx not found**: Install uvx: `pip install uvx`
2. **audible-cli issues**: Update with `uvx --from audible-cli audible --version`
3. **gum not available**: Script will fall back to basic output

## Advanced Usage

### Batch Processing Multiple Profiles

```bash
# Download from multiple accounts
for profile in personal work; do
    ./audible-download.sh --profile "$profile" --all
done
```

### Selective Downloads

```bash
# Combine with audible-cli for selective downloads
uvx --from audible-cli audible library list | grep "specific book"
./audible-download.sh --start-date "2024-01-01" --format aaxc
```

### Automation

```bash
# Daily sync of new books
crontab -e
# Add: 0 2 * * * /path/to/audible-download.sh --start-date "$(date -d '1 day ago' +%Y-%m-%d)" --all
```

## Configuration

The script reads audible-cli configuration from:
- `~/.config/audible/config.toml`
- Profile-specific settings
- Authentication tokens

### Environment Variables

- `AUDIBLE_DOWNLOAD_DIR`: Default download directory
- `AUDIBLE_DEFAULT_PROFILE`: Default profile to use
- `AUDIBLE_DEFAULT_FORMAT`: Default download format

## Error Handling

The script provides comprehensive error handling:

- Validates all input parameters
- Checks for required dependencies
- Verifies authentication before downloading
- Provides clear error messages with suggestions
- Graceful handling of network issues
- Safe handling of interrupted downloads