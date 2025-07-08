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

## Development Log

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

#### Git Workflow
- Created feature branch: feat/audiobook-splitter
- Initial commit: Basic script with parallel processing
- Enhancement commit: Switched to ffmpeg segment muxer with progress tracking
- Updated README.md with comprehensive documentation
- Created PR with detailed technical description

#### Files Modified
- `audiobook-split.sh`: Main script implementation (executable)
- `README.md`: Added comprehensive documentation with features, usage, examples
- `CLAUDE.md`: This development log

#### Usage Examples
```bash
# Basic usage
./audiobook-split.sh audiobook.m4a

# Custom segment duration (10 minutes)
./audiobook-split.sh audiobook.m4b 600

# Custom output directory
./audiobook-split.sh audiobook.mp3 480 -O /media/usb/audiobooks

# Show help
./audiobook-split.sh -h
```

#### Lessons Learned
- ffmpeg's segment muxer is more efficient than manual parallel processing
- Progress tracking significantly improves UX for long-running operations
- Filename sanitization is crucial for cross-platform compatibility
- Fallback implementations ensure compatibility across different tool versions

### Audiobook Processing Pipeline Implementation (Session: 2025-07-05)

Created comprehensive audiobook processing pipeline combining audible-cli, format conversion, and existing audiobook-split functionality.

#### New Scripts Created

##### audible-download.sh
- **Purpose**: Download audiobooks from Audible using audible-cli with configuration options
- **Key features**: Multiple formats (AAXC, AAX, PDF), date filtering, profile support, dry-run mode
- **Dependencies**: uvx, audible-cli, gum (optional)
- **Setup requirement**: `uvx --from audible-cli audible quickstart` for authentication

##### audiobook-pipeline.sh (Main Implementation)
- **Purpose**: Complete pipeline from Audible download to OpenSwim-ready MP3 files
- **Architecture**: Download → Convert → Split workflow with interactive selection
- **Target use case**: Prepare audiobooks for OpenSwim MP3 player

#### Pipeline Workflow
1. **Activation bytes retrieval**: Uses `audible activation-bytes` command
2. **Library listing**: Fetches complete Audible library via `audible library export`
3. **Interactive selection**: Gum-based multi-select interface for targeted processing
4. **Download**: Downloads selected audiobooks in AAX/AAXC format
5. **Format conversion**: AAX/AAXC → M4B using ffmpeg with activation bytes
6. **MP3 splitting**: M4B → individual MP3 files using existing audiobook-split.sh
7. **Organization**: Creates book-specific folders in ~/Audiobooks/OpenSwim/

#### Technical Implementation Details

**Activation Bytes & Conversion**:
- Uses ffmpeg 4.4+ for AAXC support (version validation included)
- AAX conversion: `ffmpeg -activation_bytes BYTES -i input.aax -c copy output.m4b`
- AAXC conversion: `ffmpeg -i input.aaxc -c copy output.m4b` (no activation bytes needed)
- Preserves chapters and metadata during conversion

**Command Format Discovery**:
- Initial issue: Used `--output-format json` (incorrect)
- Solution: Discovered correct format is `--format json`
- Fallback strategy: Tries multiple command variations for compatibility

**Interactive Selection**:
- Uses gum's multi-select (`gum choose --no-limit`)
- Proper cancellation handling (Ctrl+C detection)
- Clean output parsing with debug message filtering

#### Key Challenges Solved

**Library Output Parsing**:
- Problem: Debug messages mixed with actual library data
- Solution: Separate stderr for debug output (`>&2`), clean data filtering
- Regex filtering: Remove gum-styled output, error messages, empty lines

**User Experience Issues**:
- Problem: Script continued after Ctrl+C cancellation
- Solution: Proper exit code handling with `set +e`/`set -e` toggle
- Clear user instructions for selection interface

**Format Compatibility**:
- Problem: audible-cli command variations across versions
- Solution: Multiple format attempts with graceful fallbacks
- Support for both JSON and non-JSON output formats

#### Directory Structure
```
~/Audiobooks/audible/          (temporary downloads)
~/Audiobooks/OpenSwim/         (final MP3 files)
└── BookTitle/                 (sanitized folder names)
    ├── booktitle_01.mp3       (5-minute segments by default)
    ├── booktitle_02.mp3
    └── ...
```

#### Dependencies & Requirements
- **uvx**: For running audible-cli
- **audible-cli**: Audible library access and downloading
- **ffmpeg 4.4+**: AAX/AAXC format support and conversion
- **gum**: Interactive selection interface
- **jq**: JSON parsing for library data
- **audiobook-split.sh**: Existing script for MP3 segmentation

#### Files Modified/Created
- `audiobook-pipeline.sh`: Main pipeline script (executable)
- `audible-download.sh`: Standalone Audible downloader (executable)
- `README.md`: Updated with new scripts, alphabetical ordering, table of contents
- `CLAUDE.md`: This development log update

#### Usage Examples
```bash
# Full interactive pipeline
./audiobook-pipeline.sh

# Use specific profile
./audiobook-pipeline.sh --profile work

# Custom segment duration (8 minutes)
./audiobook-pipeline.sh --duration 480

# Keep intermediate files for debugging
./audiobook-pipeline.sh --keep-intermediate

# Test library listing functionality
./audiobook-pipeline.sh --test-library

# Preview without processing
./audiobook-pipeline.sh --dry-run
```

#### Current Status
- ✅ Core pipeline functionality implemented
- ✅ Interactive selection with proper cancellation
- ✅ Library listing with clean output parsing
- ✅ AAX/AAXC conversion working
- ✅ Integration with existing audiobook-split.sh
- ✅ Comprehensive error handling and user feedback
- ✅ Documentation updated

#### Known Limitations
- Requires manual authentication setup with audible-cli
- Dependent on specific audible-cli command format (may need updates for future versions)
- JSON parsing assumes specific library export format

#### Lessons Learned
- **API exploration**: Command-line tools often have undocumented variations - test multiple formats
- **Output separation**: Clean separation of debug/log output from actual data is crucial
- **User cancellation**: Always handle Ctrl+C gracefully in interactive scripts
- **Version compatibility**: Check tool versions and provide fallbacks
- **Pipeline design**: Modular approach allows reuse of existing components (audiobook-split.sh)

## Development Reminders
- Update the README whenever you change the scripts