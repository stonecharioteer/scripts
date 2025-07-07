# Claude Development Context

## Repository Purpose
Personal utility scripts for automation and file processing tasks. Scripts range from simple one-liners to comprehensive bash utilities for tasks like format conversion, file manipulation, and system automation.

## Development Guidelines
- **Language preference**: Bash for shell scripts, with focus on portability
- **Quality standards**: All scripts must pass shellcheck validation
- **Best practices**: Follow bash scripting conventions, proper error handling, input validation
- **Dependencies**: Document all external tool requirements (ffmpeg, gum, etc.)
- **User experience**: Provide helpful error messages, progress feedback, and comprehensive help text
- **Compatibility**: Consider cross-platform compatibility, especially for filename handling (FAT32, etc.)

## Script Requirements
- Executable permissions and proper shebang
- Command-line argument parsing with help options (-h/--help)
- Input validation and dependency checking
- Error handling with meaningful messages
- Progress indicators for long-running operations
- Clean, maintainable code structure

## Coding Style & Preferences
*This section is updated continuously as coding preferences and patterns are observed*

- **Filename conventions**: Use descriptive names with hyphens (e.g., `audiobook-split.sh`)
- **Output file naming**: When custom output directory is specified, use directory name as file prefix
- **File naming simplicity**: Avoid unnecessary words like "_segment" in filenames to keep paths shorter
- **Dynamic numbering**: Use minimum digits needed based on total count (2 for <100, 3 for <1000, 4 for >=1000)
- **Human-friendly numbering**: Start file numbering from 1 instead of 0
- **Output analysis**: Provide comprehensive summary with file statistics and anomaly detection after processing
- **Performance optimization**: Intelligent thread count based on CPU architecture and system specs for optimal performance
- **README updates**: Always update README when making changes to scripts for comprehensive documentation
- **Progress feedback**: Prioritize user experience with real-time progress indicators
- **Memory efficiency**: Prefer single-pass processing over parallel when memory is a concern
- **Compatibility**: Consider older tool versions and provide fallbacks
- **Documentation**: Comprehensive README updates with features, examples, and technical details
- **Git workflow**: Feature branches with descriptive commit messages, squash merges preferred
- **Smart UI patterns**: Only show optional prompts when using default values, not when user specifies explicit values

## Development Workflow Guidelines
- **Remember to not commit to main.**

## System Safety Guidelines
- NEVER try to use pkill to kill a generic process like `python3`!!!

## Development Log

### Conversation Management Strategy
- Store our conversation in `conversation.md` so that we record everything we talk about locally and don't forget when disconnected or if the process is killed

### audiobook-split.sh Implementation (Session: 2025-07-01)

Created a comprehensive audiobook splitting script with the following features:

#### Initial Implementation
- **Purpose**: Split audiobooks (m4a, m4b, mp3) into smaller segments for easier MP3 player usage
- **Default segment size**: 5 minutes (300 seconds), configurable
- **Output format**: MP3 files with 128k bitrate
- **Filename sanitization**: FAT32-compatible (lowercase, no special chars, underscores replace spaces)
- **Numbering**: 4-digit zero-padded segments (0001-9999) for proper sorting on MP3 players

#### Architecture Evolution
1. **Initial approach**: Parallel processing with multiple ffmpeg instances
2. **Problem identified**: High RAM usage due to multiple processes reading large files
3. **Final solution**: ffmpeg's built-in segment muxer (-f segment) for efficiency

#### Key Features Implemented
- **Command-line interface**: Argument parsing with help system (-h/--help)
- **Input validation**: File format checking, duration validation, dependency verification
- **Output directory option**: -O/--output-dir for custom locations
- **Progress tracking**: Real-time progress with percentage, elapsed time, and ETA
- **Compatibility**: Fallback for older gum versions without progress command
- **Error handling**: Comprehensive validation and cleanup

#### Technical Details
- **Dependencies**: ffmpeg (audio processing), gum (UI styling)
- **Progress implementation**: Uses ffmpeg's -progress flag for accurate tracking
- **Memory efficiency**: Single-pass processing, reads file once
- **Shellcheck validated**: Follows bash best practices
- **Progress display**: "🔄 45% (02:15 / 17:18:34) | Elapsed: 01:30 | ETA: 02:15"

#### Lessons Learned
- ffmpeg's segment muxer is more efficient than manual parallel processing
- Progress tracking significantly improves UX for long-running operations
- Filename sanitization is crucial for cross-platform compatibility
- Fallback implementations ensure compatibility across different tool versions

### highlight-manager.sh Implementation (Session: 2025-07-07)

Created a comprehensive Kindle highlights management system with DuckDB integration:

#### Initial Implementation
- **Purpose**: Convert Kindle myClippings format to structured database and provide elegant viewing interface
- **Database**: DuckDB for robust storage with proper schema and indexing
- **Text processing**: Book/author parsing, content cleaning, duplicate detection via SHA256 hashing
- **UI**: Beautiful terminal interface using gum for styling and formatting

#### Architecture Evolution
1. **Initial approach**: Direct myClippings parsing with complex bash loops
2. **Problem identified**: Parsing hang issues and complex quote escaping in SQL
3. **Intermediate solution**: Two-stage process using JSON conversion + Python/SQLite bridge
4. **Final approach**: Integrated workflow with DuckDB COPY command and tab-separated output for clean data extraction

#### Key Features Implemented
- **Integrated architecture**: Single script handling both import and display functionality
- **Import command**: Processes myClippings.txt with duplicate detection and content normalization
- **Show command**: Beautiful display with text wrapping, proper spacing, and metadata formatting
- **Content processing**: Removes trailing spaces, em-dashes, normalizes whitespace
- **Book/author separation**: Parses "Title (Author)" format into separate database fields
- **Configurable options**: Custom database path, variable highlight count display

#### Sorting Enhancement (Session: 2025-07-07)

Added flexible sorting functionality to improve highlight organization and user experience:

##### Features Added
- **--sort-by flag**: Support for `location` or `date_added` sorting fields
- **--sort-order flag**: Support for `asc` or `desc` ordering
- **Default behavior**: `location ASC, date_added ASC, book_title ASC` for logical reading order
- **Alternative sorting**: `--sort-by date_added` changes to `date_added ASC, location ASC, book_title ASC`
- **Smart UI behavior**: Only prompts for full highlights view when using default count (not when user specifies -n/--number)

##### Technical Implementation
- **Dynamic ORDER BY clause**: Built at runtime based on user parameters
- **Input validation**: Validates sort field and order parameters with helpful error messages
- **Consistent sorting**: Applied to both main display and full highlights viewer
- **Parameter passing**: Extended function signatures to pass sort parameters through the call chain

##### Usage Examples
```bash
./highlight-manager.sh show                                    # Default: location ascending
./highlight-manager.sh show --sort-by date_added              # Date added ascending  
./highlight-manager.sh show --sort-by location --sort-order desc  # Location descending
./highlight-manager.sh show -n 5 --sort-by date_added         # 5 highlights, date sorted, no prompt
```

##### UX Improvements
- **Contextual prompts**: Only show "view full highlights" prompt when using default count
- **Clear documentation**: Updated help text with sorting explanations and examples
- **Intuitive defaults**: Location-based sorting for logical reading progression

##### Lessons Learned
- **Smart UI patterns**: Users who specify explicit values (like count) don't want additional prompts
- **Flexible sorting**: Multiple sort criteria provide better organization for different use cases
- **Parameter validation**: Early validation with clear error messages improves user experience
- **Consistent behavior**: Sorting should work the same across all display modes