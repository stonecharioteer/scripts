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
- **Documentation context**: Always include a brief "why" paragraph at the start of each script's README section explaining the real-world problem it solves and the specific use case, before diving into technical details

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

### Power Monitor Enhanced Alternative Detection (Session: 2025-07-11)

Major improvements to power monitoring system's network detection reliability and user feedback, fixing database compatibility issues and adding comprehensive alternative detection methods.

#### Database and SQL Compatibility Fixes
- **Problem**: Multiple DuckDB compatibility issues causing failures in status/uptime commands
- **Solution**: 
  - Fixed `julianday()` function calls → `EXTRACT('epoch' FROM timestamp)` for DuckDB compatibility
  - Created `execute_sql_clean()` function using `duckdb -noheader -list` for clean pipe-delimited output
  - Updated all data parsing to handle clean output format instead of table-formatted results
  - Fixed MAC address truncation by using `cut -d: -f2-` to preserve full MAC addresses
- **Result**: All commands (record, status, uptime) now work correctly with proper data parsing

#### Enhanced Alternative Network Detection
- **Problem**: Devices not responding to ping were marked as failed even if reachable via other methods
- **Solution**: Implemented robust three-stage detection process:
  1. **Primary**: Standard ping + MAC validation
  2. **Alternative Method 1**: Check ARP table for existing entry with correct MAC
  3. **Alternative Method 2**: Refresh ARP cache and re-check
- **Enhanced User Messaging**: Added informative messages for all alternative detection scenarios:
  - Interactive mode: Color-coded with emojis (`⚠`, `✓`, `⟳`, `✗`)
  - Non-interactive mode: Plain text INFO/WARNING messages suitable for cron logs
  - **Device Context**: All messages include label, IP, and room (`fridge (192.168.100.110, vinay-bedroom)`)

#### Database Relationship Management
- **Problem**: Foreign key constraint errors when switches/rooms didn't exist in database
- **Solution**: 
  - Auto-create rooms before inserting switch status
  - Auto-create/update switches before inserting status records
  - Fixed DuckDB syntax issues (`INSERT OR IGNORE` → `INSERT ... ON CONFLICT ... DO NOTHING`)
- **Result**: Robust database operations that handle missing entities gracefully

#### Alternative Detection Message Examples
```bash
# Interactive Mode Examples:
⚠ fridge (192.168.100.110, vinay-bedroom) not responding to ping, checking ARP table...
✓ fridge (192.168.100.110, vinay-bedroom) detected via ARP table (ping failed but MAC verified)
⟳ Refreshing ARP cache for fridge (192.168.100.110, vinay-bedroom)...
✓ fridge (192.168.100.110, vinay-bedroom) detected after ARP refresh (ping failed but MAC verified)
✗ fridge (192.168.100.110, vinay-bedroom) not reachable via ping or ARP table

# Non-Interactive Mode Examples (cron-friendly):
INFO: fridge (192.168.100.110, vinay-bedroom) not responding to ping, checking ARP table
INFO: fridge (192.168.100.110, vinay-bedroom) detected via ARP table (ping failed but MAC verified)
INFO: Refreshing ARP cache for fridge (192.168.100.110, vinay-bedroom)
WARNING: fridge (192.168.100.110, vinay-bedroom) not reachable via ping or ARP table
```

#### Technical Implementation Details
- **Function Signatures**: Updated `check_switch_authentic()` to accept label and room parameters
- **Message Context**: All alternative detection messages include device identification (label, IP, room)
- **Database Fields**: Added `alternative_method_used` tracking for monitoring/analysis
- **Error Handling**: Comprehensive validation and graceful fallbacks throughout detection process
- **Auto-Detection**: Maintains existing auto-detection of non-interactive environments

#### Benefits Achieved
- **Reliability**: Devices with ping disabled/blocked are still properly detected and monitored
- **Visibility**: Users can identify network configuration issues and device behavior patterns
- **Debugging**: Clear context about which devices and rooms are experiencing issues
- **Automation-Friendly**: Clean log messages suitable for automated monitoring systems
- **Database Integrity**: Robust schema management prevents foreign key constraint errors

#### Status
- ✅ Enhanced alternative detection with three-stage validation process
- ✅ Comprehensive user messaging with device context (label, IP, room)
- ✅ Database compatibility fixes for all DuckDB operations
- ✅ Clean SQL output parsing for all status/uptime commands
- ✅ Auto-creation of missing database entities (rooms, switches)
- ✅ Full MAC address preservation in database records
- ✅ Non-interactive mode support for cron job automation

#### Real-World Impact
This enhancement solves common smart home monitoring challenges where devices:
- Disable ICMP/ping for security or power-saving reasons
- Use firewalls that block ping while allowing other traffic
- Are intermittently reachable but maintain ARP table presence
- Require network diagnostics with clear device identification

The system now provides enterprise-grade network monitoring reliability with user-friendly diagnostic feedback.

### Power Monitor System Development (Session: 2025-07-11)

Comprehensive power monitoring system for house and room-level power status tracking with backup-aware logic, MAC address validation, and beautiful gum-based UI.

#### Problem Statement
Need to monitor house power status by checking smart switch connectivity to distinguish between main power and backup power operation. Critical requirement: some switches are connected to backup power and must always be online - if they're offline, it indicates backup system failure which affects the monitoring system itself.

#### Architecture Overview
- **Modular Design**: Separated into lib/ modules for database, network, power logic, config, and UI
- **Backup-Aware Logic**: Differentiates main power switches from backup-connected switches
- **MAC Validation**: Prevents false positives from IP address conflicts using ARP table verification
- **Database Storage**: DuckDB for historical data with future migration path to Prometheus/InfluxDB
- **Beautiful UI**: Gum-styled tables with color-coded status displays

#### Power State Logic
- **Main Power Status**: Based on non-backup switches (≥50% online = power available)
- **Backup Power Status**: ALL backup-connected switches must be online
- **System States**:
  - `ONLINE` (Green): Main power available, all systems normal
  - `BACKUP` (Yellow): Running on backup power (main power lost)
  - `CRITICAL` (Red): Backup power failed, system at risk
  - `OFFLINE` (Red): No power detected anywhere

#### Key Components

**File Structure**:
```
power-monitor/
├── power-monitor.sh           # Main script with subcommands
├── lib/
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

**Database Schema**:
- `switches` table: Switch definitions with backup_connected field
- `power_status` table: House-level power tracking with main/backup separation
- `room_power_status` table: Room-level power tracking
- `switch_status` table: Individual switch status with ping/MAC validation results

**Network Validation**:
- Two-stage validation: ping connectivity + ARP MAC address verification
- Prevents false positives from IP conflicts or device replacements
- Real-time progress feedback during network checks

#### Subcommands Implementation
- `record`: Check switches, validate MAC, calculate power states, store in database
- `status`: Display current power status with room breakdown and uptime
- `uptime`: Show house/room uptime with power mode awareness
- `history`: Outage analysis with main power vs backup failure differentiation
- `rooms`: Room management and statistics
- `init`: Initialize database and directory structure

#### UI Design
- Color-coded status displays: Green (ONLINE), Yellow (BACKUP/PARTIAL), Red (CRITICAL/OFFLINE)
- Gum-styled tables with consistent formatting
- Real-time progress indicators for network operations
- Interactive room selection and navigation
- System status headers showing current power mode

#### Critical Infrastructure Monitoring
- Backup-connected switches have higher priority in monitoring
- Failed backup switches trigger CRITICAL system state
- Enhanced logging for backup system events
- Script recognizes its own dependency on backup power

#### Future Migration Strategy
- Database abstraction layer for easy migration to Prometheus/InfluxDB
- Time series data structure compatible with Grafana visualization
- Modular components allow individual replacement/upgrade
- Clear separation of storage logic from business logic

#### Development Patterns Applied
- Comprehensive help system for all subcommands (-h/--help)
- Error handling with meaningful messages and color feedback
- Progress indicators for long-running operations
- Dependency validation and graceful degradation
- Follows existing codebase patterns for consistency
- Documentation-first approach with detailed README

### Power Monitor Uptime Calculation Fix (Session: 2025-07-12)

Fixed critical issue with uptime calculation showing incorrect short durations instead of actual time since power state changes.

#### Problem Identified
- **Issue**: Uptime command was showing very short durations (e.g., 0.3m) instead of actual uptime
- **Root Cause**: `get_current_uptime()` function was calculating time since the latest database record, not since the last power state change
- **Impact**: Users couldn't see meaningful uptime information, making the monitoring system less useful

#### Technical Analysis
- **Current Logic**: Used simple query to get latest record timestamp and calculate duration from that point
- **Problem**: If power had been stable for hours but monitoring ran 5 minutes ago, it showed 5m uptime instead of actual hours
- **Expected Behavior**: Should calculate time since the last actual power status transition (OFFLINE→ONLINE, ONLINE→BACKUP, etc.)

#### Solution Implemented
- **Enhanced SQL Logic**: Used window functions with `LAG()` to detect actual status changes
- **House Uptime**: Finds last time `system_status` changed by comparing current vs previous status
- **Room Uptime**: Finds last time `room_power_on` changed by comparing current vs previous power state
- **Status Transition Detection**: Only counts records where status actually differs from previous record

#### Code Changes
**File**: `lib/database.sh:382-455`
- Replaced simple timestamp query with complex CTE using window functions
- Added `LAG()` window function to compare current status with previous record
- Filters for actual status changes using `WHERE system_status != prev_status OR prev_status IS NULL`
- Maintains backward compatibility with existing output format

#### Human-Readable Uptime Display Enhancement
- **Problem**: Uptime was only displayed in minutes (e.g., `1356.8m`)
- **Solution**: Added `format_uptime_minutes()` helper function in `lib/ui.sh`
- **Smart Formatting**: Automatically converts minutes to days/hours/minutes format
  - `45m` for just minutes
  - `1h 30m` for hours and minutes  
  - `1d 1h` for days and hours (omits zero minutes)
  - `22h 39m` for mixed durations

#### Implementation Details
- **New Function**: `format_uptime_minutes()` in `lib/ui.sh:574-613`
- **Updated Locations**: All uptime display points in `power-monitor.sh`
  - Status command room table uptime column
  - Uptime command house uptime display
  - Uptime command outage duration display
- **Decimal Handling**: Converts decimal minutes to integer for clean display
- **Null Handling**: Gracefully handles NULL/empty values with "--" fallback

#### Results Achieved
- **Before**: `Power Uptime: 1356.8m (since 2025-07-11 14:49:33)`
- **After**: `Power Uptime: 22h 39m (since 2025-07-11 14:49:33)`
- **Accurate Tracking**: Now correctly shows 22+ hours of uptime instead of minutes since last record
- **User-Friendly**: Human-readable format makes uptime information immediately useful

#### Power Logic Limitations Identified
During this session, analysis revealed current power detection logic limitations:

**Current Thresholds**:
- **Main Power**: 50% of non-backup switches must be online for ONLINE status
- **Backup Power**: 100% of backup switches must be online (any failure = CRITICAL)
- **Room Power**: 50% threshold applied uniformly to all rooms

**Known Issues**:
- **Backup Switch Sensitivity**: Single backup switch failure immediately triggers CRITICAL state
- **Fixed Thresholds**: No per-room or per-switch customization
- **Network vs Power**: No distinction between temporary network issues vs actual power loss
- **No Grace Periods**: Immediate state changes without smoothing for intermittent failures

**Future Improvement Areas** (noted for future development):
- Configurable thresholds per room or switch type
- Grace periods for intermittent failures  
- Different criticality levels for backup switches
- Weighted scoring based on switch importance
- Time-based averaging to smooth out network hiccups
- Distinction between different types of failures

#### Status
- ✅ Fixed uptime calculation to track actual state changes
- ✅ Added human-readable uptime formatting (days/hours/minutes)
- ✅ Updated all uptime display locations
- ✅ Tested and verified correct uptime values
- ✅ Documented power logic limitations for future improvement
- ⏳ Power threshold logic limitations noted but deferred (functional enough for current use)

#### Technical Impact
This fix transforms the power monitor from showing misleading short uptimes to displaying accurate, meaningful uptime information that users can rely on for understanding their power stability patterns.

### Power Monitor ARP False Positive Fix and Detection Method Tracking (Session: 2025-07-12)

Complete solution implementation for ARP table false positives with comprehensive detection method tracking for enhanced power monitoring reliability.

#### Problem Analysis and Solution
- **Issue**: Power monitor incorrectly reports devices as "online" during power outages using alternative ARP detection
- **Root Cause**: ARP table entries persist for minutes after devices go offline, creating stale entries that cause false positives
- **Solution Implemented**: Enhanced ARP freshness validation with numeric detection method tracking

#### Root Cause Analysis

**ARP Cache Persistence Behavior**:
- ARP entries remain in system cache for 60-300+ seconds after devices go offline
- `arp -n` and `ip neigh show` commands return stale entries without real-time validation
- Original logic trusted any ARP entry with matching MAC address regardless of freshness

**False Positive Detection Flow**:
1. **Ping fails** (device actually down due to power outage)
2. **Check ARP table** - finds stale entry with correct MAC from when device was last reachable
3. **System reports "detected via ARP"** - FALSE POSITIVE
4. **Device marked as `is_authentic=true`** - INCORRECT STATUS
5. **Power calculations use wrong data** - compromised monitoring accuracy

#### Solution Implementation

**Enhanced ARP Freshness Validation with Detection Method Tracking**
- **ARP State Validation**: Uses `ip neigh show` to check if entries are "REACHABLE", "DELAY", or "STALE"
- **Fresh Entry Only Logic**: Only accepts ARP entries with REACHABLE/DELAY state as valid detections
- **Stale Entry Rejection**: Treats stale ARP entries as failed detections (Method 0) to prevent false positives
- **Numeric Detection Method Tracking**: Records how each device status was determined with numeric codes

**Implementation Details**:
- **Files Modified**: 
  - `lib/network.sh` - Enhanced ARP validation functions and detection method constants
  - `lib/database.sh` - Added detection_method field to switch_status table
  - `sql/init.sql` - Database schema updates with new field and indexing
  - `power-monitor.sh` - Updated parsing and recording logic
- **Database Changes**: Added `detection_method INTEGER` field to `switch_status` table with proper indexing

**Detection Method Constants** (lib/network.sh:18-26):
- **0 - FAILED**: Device failed all detection methods (includes stale ARP entries)
- **1 - PING_ONLY**: Ping successful, MAC validation skipped/failed  
- **2 - PING_MAC**: Ping successful + MAC validation successful (most reliable)
- **3 - ARP_FRESH**: Ping failed, detected via fresh ARP entry (REACHABLE/DELAY state)
- **4 - ARP_STALE**: DEPRECATED - stale entries now treated as FAILED (0)
- **5 - ARP_REFRESH**: Ping failed, detected after ARP cache refresh
- **6 - ARPING**: Ping failed, detected via arping probe (real-time validation)

#### Enhanced Detection Logic

**New ARP Validation Flow**:
1. **Ping test** (primary validation) - if successful, use Method 2 (PING_MAC) or Method 1 (PING_ONLY)
2. **If ping fails**, check ARP table for entry with matching MAC
3. **Parse ARP state** using `ip neigh show` to determine freshness (REACHABLE/DELAY vs STALE/FAILED)
4. **Fresh ARP entries** → Device detected as online (Method 3 - ARP_FRESH)
5. **Stale ARP entries** → Device treated as failed/offline (Method 0 - FAILED)
6. **ARP refresh attempt** → If successful after refresh, use Method 5 (ARP_REFRESH)

**Key Functions Added/Modified**:
- `get_arp_entry_info()` - New function to extract MAC, state, and freshness from ARP table
- `validate_mac_address()` - Enhanced with freshness validation using `POWER_MONITOR_ARP_REQUIRE_FRESH` env var
- `check_switch_authentic()` - Updated to track and return detection method codes
- `insert_switch_status()` - Added detection_method parameter to database recording

#### Configuration Options
**Environment Variables** (lib/network.sh:13-16):
- `POWER_MONITOR_ARP_REQUIRE_FRESH=true` - Require fresh ARP entries for validation (default: true)
- `POWER_MONITOR_ARP_FALLBACK_ARPING=false` - Use arping for real-time validation when available (default: false)  
- `POWER_MONITOR_ARP_DEBUG_LOGGING=false` - Enable detailed ARP debugging (default: false)

#### Database Schema Changes
**New Field**: `detection_method INTEGER NOT NULL DEFAULT 0` added to `switch_status` table
**Index Added**: `idx_switch_status_detection_method` for efficient querying by detection method
**View Updated**: `current_switch_status` view includes detection_method field

#### User Experience Improvements
**Enhanced Messages**:
- `⚠ fridge has stale ARP entry (treating as offline)` - Clear indication when stale entries are rejected
- `✓ fridge detected via fresh ARP entry (ping failed but MAC verified)` - Success with method clarity
- Debug logging shows ARP state and freshness: `[DEBUG] ARP info for 192.168.1.100: MAC=aa:bb:cc:dd:ee:ff, State=REACHABLE, Fresh=true`

#### Testing Results
**Verification Commands**:
```bash
# Test enhanced detection with debug logging
POWER_MONITOR_DEBUG=1 ./power-monitor.sh record

# Check detection methods in database  
duckdb ~/Documents/power.db -c "SELECT switch_label, ping_successful, is_authentic, detection_method FROM switch_status ORDER BY timestamp DESC LIMIT 5;"
```

**Results Confirmed**:
- Method 2 (PING_MAC): Working devices show ping success + MAC validation
- Method 0 (FAILED): Offline devices correctly show failed detection (no false positives from stale ARP)
- Method 3 (ARP_FRESH): Devices with ping disabled but actually reachable still detected via fresh ARP

#### Status
- ✅ **Enhanced ARP Freshness Validation**: Implemented with state checking (REACHABLE/DELAY vs STALE)
- ✅ **Detection Method Tracking**: All device checks now record numeric detection method codes
- ✅ **Database Schema Updates**: Added detection_method field with proper indexing
- ✅ **Stale Entry Rejection**: Stale ARP entries treated as failed to prevent false positives
- ✅ **Configuration Options**: Environment variables for customizing ARP validation behavior
- ✅ **Enhanced User Messages**: Clear indication of detection method and warnings for stale entries
- ✅ **Testing Verified**: Confirmed elimination of false positives while maintaining ping-disabled device support
- ✅ **Documentation Updated**: README and code comments reflect new detection method logic

#### Real-World Impact
This solution eliminates the critical false positive issue where power monitors incorrectly report devices as online during actual power outages. The comprehensive detection method tracking provides enterprise-grade visibility into network monitoring reliability, enabling:

- **Accurate Power Outage Detection**: No false positives from stale ARP cache entries
- **Troubleshooting Capability**: Numeric codes show exactly how each device status was determined
- **Network Configuration Insights**: Distinguish between power issues vs network configuration problems
- **Maintenance Planning**: Historical detection method data helps identify problematic devices or network segments
- **Reliability Metrics**: Track detection method reliability over time for system optimization

The enhanced system maintains backward compatibility while providing significantly improved accuracy and diagnostic capabilities for critical infrastructure monitoring.

### Power Monitor Crontab Automation and Documentation Updates (Session: 2025-07-13)

Enhanced power monitor with proper crontab automation setup, documentation improvements, and troubleshooting for common deployment issues.

#### Crontab Automation Implementation

**Problem Identified**: Power monitor cron jobs were failing silently with "duckdb is not installed" errors despite working when run manually.

**Root Cause Analysis**:
- **Minimal Environment**: Cron runs with minimal PATH that doesn't include user-installed tools
- **duckdb Location**: Installed in `~/.local/bin/duckdb` but not accessible to cron
- **Cascading Failures**: Database access errors were actually PATH-related, not permission issues
- **Silent Failures**: No logging made troubleshooting difficult

#### Solution Implementation

**Comprehensive Crontab Configuration**:
```bash
# Essential PATH setup for cron environment
PATH=/home/username/.local/bin:/usr/local/bin:/usr/bin:/bin

# Automated monitoring with proper locking and logging
*/5 * * * * /usr/bin/flock -n /tmp/power-monitor.lock /path/to/power-monitor.sh record 2>&1 | logger -t power-monitor
```

**Key Components**:
1. **PATH Environment Variable**: Explicit PATH setup to include user binary locations
2. **File Locking with flock**: Prevents multiple instances using non-blocking lock (`-n` flag)
3. **System Logging with logger**: Automatic log rotation via syslog instead of local files
4. **Error Capture**: `2>&1` captures both stdout and stderr for complete debugging

#### Troubleshooting Tools and Techniques

**Log Monitoring Commands**:
```bash
# Real-time monitoring
journalctl -t power-monitor -f

# Historical analysis
journalctl -t power-monitor --since "1 hour ago"

# Database verification
duckdb ~/Documents/power.db -c "SELECT COUNT(*) FROM power_status WHERE DATE(timestamp) = '$(date +%Y-%m-%d)';"
```

**Common Issues Identified**:
- **"duckdb is not installed"**: PATH not set in crontab environment
- **"Cannot access database"**: Usually follows from duckdb not found
- **Multiple instances**: Solved with flock file locking
- **Silent failures**: Resolved with logger integration
- **Gap in monitoring**: Database records missing during cron failures

#### Documentation Enhancements

**README.md Improvements**:
- **Comprehensive Crontab Section**: Added detailed automation setup with examples
- **PATH Gotcha Documentation**: Explicit warning about cron environment limitations
- **flock Usage Guidelines**: Multiple instance prevention with examples
- **logger Best Practices**: System logging vs local file approaches
- **Troubleshooting Section**: Step-by-step debugging for common issues
- **Testing Commands**: Verification procedures for cron setup

**File Organization**:
- **Moved Documentation**: `docs/power-monitor.readme.md` → `power-monitor/README.md`
- **Updated Root README**: Fixed broken link to power-monitor documentation
- **Proper Linking**: Created relative link structure for better navigation

#### Database Management

**Room Configuration Fix**:
- **Issue**: Fridge switch incorrectly assigned to "vinay-bedroom" instead of "kitchen"
- **Challenge**: Foreign key constraints preventing simple UPDATE operations
- **Solution**: Added kitchen room first, then updated switch and related status records
- **Outcome**: Proper room assignment with maintained referential integrity

#### Advanced Logging Patterns

**Alternative Logging Approaches**:
```bash
# Option 1: System syslog (recommended)
*/5 * * * * command 2>&1 | logger -t power-monitor

# Option 2: Custom log with rotation
*/5 * * * * command >> ~/.local/log/power-monitor.log 2>&1

# Option 3: Silent operation (not recommended)
*/5 * * * * command >/dev/null 2>&1
```

**Benefits of logger Approach**:
- **Automatic Rotation**: System handles log rotation via logrotate
- **Centralized Logging**: Integration with system logging infrastructure
- **Real-time Monitoring**: `journalctl -f` for live log tailing
- **Search Capabilities**: Built-in filtering and date-based searching
- **No Maintenance**: No manual log file management required

#### Deployment Best Practices

**Testing Methodology**:
1. **Manual Execution**: Test exact cron command manually first
2. **Database Verification**: Check for new records after test runs
3. **Log Monitoring**: Watch logs during initial deployment
4. **Gap Detection**: Monitor for missing time periods in data
5. **Performance Validation**: Ensure monitoring doesn't impact system performance

**Configuration Validation**:
- **Dependency Checking**: Verify all required tools available in cron PATH
- **Permission Verification**: Ensure database and log file accessibility
- **Network Testing**: Validate switch connectivity from cron environment
- **Timing Verification**: Confirm monitoring frequency meets requirements

#### Status and Outcomes

**Deployment Results**:
- ✅ **Reliable Automation**: Cron jobs now run successfully every 5 minutes
- ✅ **Complete Logging**: Full visibility into monitoring operations and failures
- ✅ **No More Silent Failures**: All errors captured and accessible via journalctl
- ✅ **Prevented Race Conditions**: flock eliminates overlapping execution issues
- ✅ **Comprehensive Documentation**: Complete setup and troubleshooting guide
- ✅ **Database Consistency**: Proper room assignments and foreign key integrity
- ✅ **Monitoring Verification**: Tools and commands for ongoing system health checks

**Key Learnings**:
- **Environment Differences**: Cron vs shell environments require explicit PATH management
- **Debugging Importance**: Proper logging essential for automated system troubleshooting
- **Lock File Benefits**: Simple file locking prevents complex race condition issues
- **Documentation Value**: Comprehensive guides prevent repeated troubleshooting efforts
- **System Integration**: logger command provides powerful logging without complexity

**Real-World Impact**:
This implementation transforms the power monitor from a manually-run tool to a fully automated monitoring system suitable for production deployment. The comprehensive documentation and troubleshooting guides enable reliable setup and maintenance across different environments and users.

The automation improvements enable:
- **Continuous Monitoring**: 24/7 power status tracking without manual intervention
- **Historical Analysis**: Long-term data collection for trend analysis and capacity planning
- **Alert Capability**: Foundation for future alerting and notification systems
- **System Integration**: Clean logging suitable for integration with monitoring dashboards
- **Maintenance Efficiency**: Self-documenting setup reduces support overhead