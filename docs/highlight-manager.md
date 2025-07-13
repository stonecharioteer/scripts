# Highlight Manager

## Purpose

I read on multiple digital devices and use KOReader everywhere, but it doesn't sync highlights well across devices. I don't want to use the kohighlights plugin for Calibre because that would require using Calibre to maintain the library on all devices. Instead, I export highlights in myClippings.txt format from each device and use this script to consolidate them all in one place.

## Overview

Comprehensive Kindle highlights management system with DuckDB integration for storage, organization, and beautiful terminal display.

## Requirements

- `duckdb` for database storage
- `gum` for terminal UI styling
- `jq` for JSON processing
- `python3` for data transformation

## Features

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

## Usage

```bash
./highlight-manager.sh <subcommand> [options]
./highlight-manager.sh -h  # Show help
```

## Subcommands

### import - Import Highlights
Import highlights from myClippings file(s) to database.

```bash
./highlight-manager.sh import [INPUT_FILE...]
```

**Options:**
- `INPUT_FILE...` - One or more myClippings files to import (default: myClippings.txt)
- Supports wildcards: `*.clippings.txt`, `book*.txt`, etc.

### show - Display Highlights
Display highlights from database with beautiful formatting.

```bash
./highlight-manager.sh show [OPTIONS]
```

**Options:**
- `-n, --number COUNT` - Number of highlights to show (default: 10)
- `--sort-by FIELD` - Sort by field: location, date_added (default: location)
- `--sort-order ORDER` - Sort order: asc, desc (default: asc)

### summary - Database Overview
Show database statistics and overview.

```bash
./highlight-manager.sh summary
```

## Global Options

- `--database-path PATH` - Database file path (default: ~/Documents/highlights.db)
- `-h, --help` - Show help message

## Examples

### Import Commands
```bash
# Import single file
./highlight-manager.sh import myClippings.txt

# Import multiple files
./highlight-manager.sh import file1.txt file2.txt file3.txt

# Import with wildcards
./highlight-manager.sh import *.clippings.txt

# Custom database + multiple files
./highlight-manager.sh --database-path ~/custom.db import book*.txt
```

### Show Commands
```bash
# Show 5 highlights (no prompt for full view)
./highlight-manager.sh show -n 5

# Sort by date added (ascending)
./highlight-manager.sh show --sort-by date_added

# Sort by location (descending)
./highlight-manager.sh show --sort-by location --sort-order desc

# Show 20 highlights sorted by date
./highlight-manager.sh show --number 20 --sort-by date_added
```

### Summary Command
```bash
# Show database overview
./highlight-manager.sh summary

# Summary for custom database
./highlight-manager.sh summary --database-path ~/custom.db
```

## Import Output Format

### Single File Import
```
✅ Import completed:
   - 127 quotes found in file
   - 126 new highlights imported
   - 1 duplicates skipped (already in database)
   - 130 total highlights in database
```

### Multiple File Import
```
📊 Overall Import Summary:
   - 131 total quotes found across all files
   - 126 new highlights imported
   - 5 duplicates skipped
   - 149 total highlights in database
```

## Summary Output Format

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

## Show Display Format

```
1. Empire of AI by Karen Hao

   Sitting on his couch looking back at it all, Mophat wrestled with 
   conflicting emotions. "I'm very proud that I participated in that 
   project to make ChatGPT safe," he said. "But now the question I always 
   ask myself: Was my input worth what I received in return?"

   📍 page 351
   📅 Sunday, July 06, 2025 12:52:01 PM
```

## Database Schema

The highlights database includes the following fields:

- `book_title` - Book title (extracted from "Title (Author)" format)
- `author` - Author name (extracted from parentheses)
- `highlight_type` - Type of highlight (highlight, note, bookmark)
- `location` - Page number or location reference
- `date_added` - Timestamp when highlight was created
- `content` - Full highlight text (cleaned and normalized)
- `content_hash` - SHA256 hash for duplicate detection
- `created_at` - Import timestamp

### Schema Details

```sql
CREATE TABLE highlights (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    book_title VARCHAR NOT NULL,
    author VARCHAR,
    highlight_type VARCHAR NOT NULL,
    location VARCHAR,
    date_added TIMESTAMP,
    content TEXT NOT NULL,
    content_hash VARCHAR(64) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for performance
CREATE INDEX idx_book_title ON highlights(book_title);
CREATE INDEX idx_author ON highlights(author);
CREATE INDEX idx_date_added ON highlights(date_added);
CREATE INDEX idx_content_hash ON highlights(content_hash);
```

## myClippings File Format

The script expects Kindle's standard myClippings.txt format:

```
Book Title (Author Name)
- Your Highlight on page 123 | location 1234-1245 | Added on Monday, January 1, 2024 12:00:00 PM

The actual highlight content goes here and can span
multiple lines until the separator.

==========
Next Book Title (Another Author)
- Your Highlight on page 45 | location 567-678 | Added on Tuesday, January 2, 2024 1:00:00 PM

Another highlight content here.

==========
```

### Supported Highlight Types

- **Highlights** - Text selections with yellow highlighting
- **Notes** - User-added annotations and comments  
- **Bookmarks** - Page markers without text content

### Date Format Support

The script handles various Kindle date formats:
- `Monday, January 1, 2024 12:00:00 PM`
- `January 1, 2024 12:00:00 PM`
- `Mon, Jan 1, 2024 12:00:00 PM`

## Content Processing

### Text Normalization
- Removes trailing spaces and em-dashes
- Normalizes whitespace (multiple spaces → single space)
- Handles Unicode characters properly
- Preserves line breaks in multi-line highlights

### Book/Author Parsing
- Extracts title from "Title (Author)" format
- Handles complex titles with parentheses
- Falls back gracefully for non-standard formats
- Stores title and author separately for better querying

### Duplicate Detection
- Uses SHA256 hashing of normalized content
- Compares book title, author, and highlight text
- Ignores minor differences in location/date
- Provides clear feedback on duplicates found

## Performance

### Database Optimization
- Indexed fields for fast queries
- Efficient duplicate detection
- Minimal memory usage during import
- Supports large highlight collections (10,000+ highlights)

### Import Performance
- Batch processing for multiple files
- Progress indication for large files
- Memory-efficient streaming for large imports
- Parallel processing for multiple files

## Integration with Reading Workflow

### Multi-Device Sync
```bash
# Export from each device to separate files
# Device 1: kindle_device1.txt
# Device 2: kindle_device2.txt
# KOReader: koreader_exports.txt

# Import all at once
./highlight-manager.sh import kindle_*.txt koreader_*.txt
```

### Periodic Updates
```bash
# Weekly highlight sync
crontab -e
# Add: 0 18 * * 0 /path/to/highlight-manager.sh import ~/Dropbox/Kindle/*.txt
```

### Export for Other Tools
```bash
# Export highlights for analysis
duckdb ~/Documents/highlights.db -c "
    SELECT book_title, author, content, date_added 
    FROM highlights 
    ORDER BY date_added DESC
" > highlights_export.csv
```

## Advanced Usage

### Custom Queries
```bash
# Most highlighted books
duckdb ~/Documents/highlights.db -c "
    SELECT book_title, author, COUNT(*) as highlight_count 
    FROM highlights 
    GROUP BY book_title, author 
    ORDER BY highlight_count DESC 
    LIMIT 10
"

# Recent highlights (last 30 days)
duckdb ~/Documents/highlights.db -c "
    SELECT book_title, content, date_added 
    FROM highlights 
    WHERE date_added > datetime('now', '-30 days')
    ORDER BY date_added DESC
"
```

### Backup and Restore
```bash
# Backup database
cp ~/Documents/highlights.db ~/Documents/highlights_backup.db

# Export all data
duckdb ~/Documents/highlights.db -c ".dump" > highlights_backup.sql

# Restore from backup
duckdb ~/Documents/highlights_restored.db < highlights_backup.sql
```

## Troubleshooting

### Common Issues

1. **File encoding errors**: Ensure myClippings files are UTF-8 encoded
2. **Date parsing failures**: Check that dates match expected Kindle format
3. **Duplicate detection issues**: Content hashing is case-sensitive
4. **Database locked**: Close other processes accessing the database

### Debug Mode
Enable verbose output for troubleshooting:
```bash
HIGHLIGHT_MANAGER_DEBUG=1 ./highlight-manager.sh import file.txt
```

### Data Validation
```bash
# Check for import issues
duckdb ~/Documents/highlights.db -c "
    SELECT book_title, COUNT(*) as count 
    FROM highlights 
    WHERE book_title = '' OR author = '' 
    GROUP BY book_title
"
```

## File Management

### Organizing myClippings Files
```bash
# Recommended directory structure
~/Reading/
├── highlights/
│   ├── kindle_main.txt
│   ├── kindle_oasis.txt
│   ├── koreader_phone.txt
│   └── archive/
│       ├── 2023_highlights.txt
│       └── 2024_highlights.txt
└── books/
```

### Automated Collection
Set up automatic collection from cloud storage:
```bash
# Sync Kindle highlights from cloud
rsync -av ~/Dropbox/Apps/Kindle/ ~/Reading/highlights/
./highlight-manager.sh import ~/Reading/highlights/*.txt
```