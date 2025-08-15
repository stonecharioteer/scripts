# Claude Development Context

## Repository Purpose
Personal utility scripts for automation and file processing tasks. Scripts range from simple one-liners to comprehensive bash utilities for tasks like format conversion, file manipulation, and system automation.

## Development Guidelines
- **Language**: Bash for shell scripts with portability focus
- **Quality**: All scripts must pass shellcheck validation
- **Dependencies**: Document external tool requirements (ffmpeg, gum, etc.)
- **UX**: Helpful error messages, progress feedback, comprehensive help text
- **Compatibility**: Cross-platform support, especially filename handling (FAT32, etc.)

## Script Requirements
- Executable permissions, proper shebang, and clean structure
- Command-line parsing with help options (-h/--help)
- Input validation, dependency checking, and error handling
- Progress indicators for long-running operations

## Coding Style & Preferences
- **Filenames**: Descriptive names with hyphens (`audiobook-split.sh`)
- **Output naming**: Use directory name as file prefix when custom output specified
- **Numbering**: Dynamic digits based on count (2 for <100, 3 for <1000), start from 1
- **Performance**: Intelligent thread count, single-pass when memory constrained
- **Documentation**: README updates with "why" context, features, examples
- **Git**: Feature branches, descriptive commits, squash merges
- **UI**: Optional prompts only with defaults, not explicit user values

## Development Rules
- **Never commit to main branch**
- **Never use pkill on generic processes like `python3`**
- **Always update README when changing scripts**
- **Read script code before attempting to use them**
- **Use ripgrep instead of grep in context (not in code)**

## Development Log

### Audiobook Pipeline Enhancement (2025-07-09)
Enhanced audiobook-pipeline.sh with modular design and smart automation:
- **Auto-conversion**: Fixed file detection using before/after comparison
- **Help system**: Added `-h/--help` for all subcommands
- **Modular commands**: Separated download, convert, split, and automate workflows
- **Auto-discovery**: Smart file detection and processing without explicit arguments
- **Multi-tier fallback**: ASIN → title → word-based file detection

### Power Monitor System Development (2025-07-11 to 2025-07-13)
Complete power monitoring system for house/room-level status tracking:

**Core Features**:
- **Backup-aware logic**: Differentiates main vs backup power switches
- **MAC validation**: Prevents IP conflict false positives via ARP table
- **Three-stage detection**: Ping → ARP check → ARP refresh fallback
- **DuckDB integration**: Fixed compatibility issues, clean SQL output parsing
- **Modular design**: Separated lib/ modules (database, network, power-logic, config, ui)

**Key Fixes**:
- **ARP false positives**: Enhanced freshness validation (REACHABLE/DELAY vs STALE)
- **Detection method tracking**: Numeric codes (0=FAILED, 1=PING_ONLY, 2=PING_MAC, 3=ARP_FRESH, etc.)
- **Uptime calculation**: Fixed to track actual state changes, not latest record time
- **Room status parsing**: Fixed cross-contamination bug using section-by-section parsing
- **Crontab automation**: PATH setup, flock locking, logger integration for production deployment

**Power States**: ONLINE (green), BACKUP (yellow), CRITICAL/OFFLINE (red)
**Monitoring**: Real-time status, historical analysis, automated cron deployment

### Locale Configuration Script (2025-08-15)
Created set-locale.sh for comprehensive locale management:

**Core Features**:
- **Automatic Setup**: Generates and configures en_US.UTF-8 locale with all LC_* variables
- **System Integration**: Updates /etc/default/locale and current session without restart
- **Cleanup Option**: Removes unused locales (--cleanup) keeping only en_US.UTF-8 and C/POSIX
- **Verification**: Complete locale status checking (--verify) with detailed output

**Key Components**:
- **Safety First**: Backup creation before cleanup, confirmation prompts for destructive actions
- **Cross-platform**: Works with different locale-gen implementations and system configurations
- **Immediate Effect**: Updates current session environment variables for instant usage
- **Space Optimization**: Cleans both locale.gen and locale archive to minimize disk usage




