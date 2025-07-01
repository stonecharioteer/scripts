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
