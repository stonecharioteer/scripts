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

(Rest of the existing content remains the same)

## Development Reminders
- Update the README whenever you change the scripts
- Test end-to-end functionality after major changes
- Consider corrupted source files when designing audio processing workflows
- **Read the code for scripts before attempting to use them.**
- Use ripgrep instead of grep when you're searching for things. I'll always have that installed. Just in your context, not in the code itself, unless I say so otherwise.

### Enhanced Auto-Conversion and Modular Design (Session: 2025-07-09)

Major enhancement to audiobook-pipeline.sh with smart auto-conversion, comprehensive help system, and modular command separation.

#### Auto-Conversion Enhancement
- **Problem**: Auto-conversion after download wasn't working due to unreliable file detection
- **Solution**: Enhanced `download_audiobook()` to return actual downloaded filename using before/after file comparison
- **Result**: Reliable auto-conversion with proper file tracking and error handling

#### Comprehensive Help System
- **Problem**: `-h`/`--help` flags didn't work for subcommands
- **Solution**: Added dedicated help functions for each subcommand:
  - `show_download_help()` - Download-specific options and examples
  - `show_convert_help()` - Convert-specific options and examples  
  - `show_split_help()` - Split-specific options and examples
  - `show_automate_help()` - Automate-specific options and examples
- **Integration**: Added `-h|--help` handling to all subcommand argument parsing

#### Smart Download Logic
- **Enhanced File Detection**: Multi-tier approach for finding existing files:
  1. ASIN-based search (primary)
  2. Title-based search (fallback)
  3. Word-based search (final fallback)
- **Skip Logic**: Detects already downloaded files and skips re-downloading
- **Conversion Check**: Only converts if M4B file doesn't exist
- **Status Reporting**: Clear feedback about existing vs new files

#### Convert Command Enhancement
- **Auto-Discovery**: When no files specified, scans raw directory for unconverted files
- **Smart Filtering**: Only processes files missing M4B versions
- **User Feedback**: Shows which files are skipped and why
- **Graceful Completion**: Handles "all converted" scenario cleanly

#### Modular Command Separation
- **Problem**: Convert command was doing both M4B conversion AND MP3 splitting
- **Solution**: Split responsibilities into separate commands:
  - `convert` command: Only converts AAX/AAXC → M4B (with chapter preservation)
  - `split` command: Only handles M4B → MP3 segmentation
  - `automate` command: Full pipeline (download → convert → split)

#### New Split Subcommand
- **Purpose**: Split M4B files into MP3 segments using existing audiobook-split.sh
- **Auto-Discovery**: Finds all M4B files in converted directory when no args provided
- **Integration**: Calls audiobook-split.sh with proper arguments and error handling
- **Features**: 
  - Supports dry-run mode
  - Proper file validation (M4B only)
  - Sanitized output directory naming
  - Comprehensive status reporting

#### Implementation Details
- **File Structure**: Added `cmd_split()` function (lines 1240-1332)
- **Routing**: Added `split` to subcommand detection and execution routing
- **Help Integration**: Added split command to main help and subcommand help system
- **Error Handling**: Comprehensive validation and status reporting throughout

#### Current Workflow
1. **Download**: `./audiobook-pipeline.sh download` - Downloads and auto-converts to M4B
2. **Convert**: `./audiobook-pipeline.sh convert` - Converts AAX/AAXC to M4B only
3. **Split**: `./audiobook-pipeline.sh split` - Splits M4B files to MP3 segments
4. **Automate**: `./audiobook-pipeline.sh automate` - Full pipeline in one command

#### Status
- ✅ Enhanced download with smart file detection
- ✅ Auto-conversion with reliable file tracking  
- ✅ Help system for all subcommands (-h/--help)
- ✅ Convert command with auto-discovery (M4B only)
- ✅ Split command implementation and routing
- ✅ Complete modular separation of concerns
- ✅ All commands support auto-discovery (no args = process all)

#### Benefits Achieved
- **Separation of Concerns**: Each command has a single, clear responsibility
- **User Choice**: Users can run individual steps or full automation
- **Efficiency**: Smart file detection avoids redundant processing
- **Usability**: Comprehensive help and auto-discovery reduce command complexity
- **Reliability**: Robust error handling and status reporting throughout