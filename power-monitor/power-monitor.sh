#!/bin/bash

# power-monitor.sh - House and room-level power monitoring with backup awareness
# Monitors smart switch connectivity to track main power vs backup power status

set -euo pipefail

# Script metadata
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_VERSION="1.0.0"

# Source all library modules
# shellcheck source=lib/database.sh
source "$SCRIPT_DIR/lib/database.sh"
# shellcheck source=lib/network.sh
source "$SCRIPT_DIR/lib/network.sh"
# shellcheck source=lib/power-logic.sh
source "$SCRIPT_DIR/lib/power-logic.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"

# Default configuration
DEFAULT_DB_PATH="$HOME/Documents/power.db"
DEFAULT_TIMEOUT=5
DEFAULT_CONFIG_DIR="$SCRIPT_DIR/config"

# Global variables
DB_PATH="${POWER_MONITOR_DB_PATH:-$DEFAULT_DB_PATH}"
CONFIG_DIR="${POWER_MONITOR_CONFIG_DIR:-$DEFAULT_CONFIG_DIR}"
TIMEOUT=$DEFAULT_TIMEOUT
VERBOSE=false
DRY_RUN=false
NON_INTERACTIVE=false

# Auto-detect if running in non-interactive mode (cron, headless, etc.)
if [[ ! -t 1 ]] || [[ -z "${TERM:-}" ]] || [[ "${TERM}" == "dumb" ]]; then
    NON_INTERACTIVE=true
fi

# Help functions

show_main_help() {
    cat << EOF
$SCRIPT_NAME - House and room-level power monitoring system

Usage: $SCRIPT_NAME <subcommand> [OPTIONS]

Monitor house power status by checking smart switch connectivity with backup-aware
logic. Distinguishes between main power and backup power operation.

SUBCOMMANDS:
    init         Initialize database and system
    record       Record current power status
    status       Display current power status and uptime
    uptime       Show detailed uptime information
    history      Show outage history and analysis
    rooms        Room management and statistics
    test         Test system functionality

GLOBAL OPTIONS:
    --database-path PATH    Database file path (default: $DEFAULT_DB_PATH)
    --config-dir PATH       Configuration directory (default: $DEFAULT_CONFIG_DIR)
    --timeout SECONDS       Network timeout (default: $DEFAULT_TIMEOUT)
    --verbose              Detailed output and debug information
    --dry-run              Show what would be done without making changes
    --non-interactive      Disable colors and UI for cron/headless use (auto-detected)
    -h, --help             Show this help message

For subcommand-specific help, use: $SCRIPT_NAME <subcommand> --help

POWER STATES:
    ONLINE      Main power available, all systems normal
    BACKUP      Running on backup power (main power lost)
    CRITICAL    Backup power failed, system at risk
    OFFLINE     No power detected anywhere

EXAMPLES:
    $SCRIPT_NAME init                    # Initialize system
    $SCRIPT_NAME record                  # Check switches and record status
    $SCRIPT_NAME status                  # Show current power status
    $SCRIPT_NAME uptime --room bedroom   # Show bedroom uptime
    $SCRIPT_NAME history --days 7       # Show last week's outages

AUTOMATION:
    # Add to crontab for regular monitoring (auto-detects non-interactive mode)
    */5 * * * * /path/to/$SCRIPT_NAME record >/dev/null 2>&1

DEPENDENCIES:
    - duckdb (database operations)
    - ping (connectivity testing)
    - arp or ip (MAC address validation)
    - jq (JSON processing)
    - gum (beautiful UI, optional)

SETUP:
    1. Edit config/switches.json with your switch details
    2. Run: $SCRIPT_NAME init
    3. Test: $SCRIPT_NAME record
    4. Monitor: $SCRIPT_NAME status

For detailed documentation, see: docs/power-monitor.readme.md
EOF
}

show_init_help() {
    cat << EOF
$SCRIPT_NAME init - Initialize database and system

Usage: $SCRIPT_NAME init [OPTIONS]

Initialize the power monitoring system by creating the database schema,
importing switch configuration, and validating dependencies.

OPTIONS:
    --force                Force reinitialization (deletes existing database)
    --database-path PATH   Database file path (default: $DEFAULT_DB_PATH)
    --config-dir PATH      Configuration directory (default: $DEFAULT_CONFIG_DIR)
    --verbose             Detailed output
    -h, --help            Show this help message

EXAMPLES:
    $SCRIPT_NAME init                # Standard initialization
    $SCRIPT_NAME init --force        # Force reinitialize
    $SCRIPT_NAME init --verbose      # Detailed output

This command will:
    1. Check system dependencies
    2. Create database schema
    3. Import switches from config/switches.json
    4. Validate configuration
    5. Create initial room records
EOF
}

show_record_help() {
    cat << EOF
$SCRIPT_NAME record - Record current power status

Usage: $SCRIPT_NAME record [OPTIONS]

Check all configured switches, validate their connectivity and MAC addresses,
calculate power states, and store results in the database.

OPTIONS:
    --timeout SECONDS     Network timeout for switch checks (default: $DEFAULT_TIMEOUT)
    --parallel JOBS       Maximum parallel switch checks (default: 10)
    --database-path PATH  Database file path (default: $DEFAULT_DB_PATH)
    --config-dir PATH     Configuration directory (default: $DEFAULT_CONFIG_DIR)
    --verbose            Detailed output and debug information
    --dry-run            Show what would be recorded without storing
    -h, --help           Show this help message

EXAMPLES:
    $SCRIPT_NAME record                     # Standard power check
    $SCRIPT_NAME record --verbose           # Detailed switch checking
    $SCRIPT_NAME record --timeout 10        # Longer timeout for slow network
    $SCRIPT_NAME record --dry-run           # Test without storing results
    $SCRIPT_NAME record --non-interactive   # Plain text for cron jobs (auto-detected)

This command will:
    1. Load switch configuration
    2. Check connectivity (ping + MAC validation)
    3. Calculate main and backup power status
    4. Determine overall system status
    5. Store results in database
    6. Auto-discover new switches
EOF
}

show_status_help() {
    cat << EOF
$SCRIPT_NAME status - Display current power status

Usage: $SCRIPT_NAME status [OPTIONS]

Display current house and room power status with uptime information.

OPTIONS:
    --room ROOM          Show status for specific room only
    --database-path PATH Database file path (default: $DEFAULT_DB_PATH)
    --config-dir PATH    Configuration directory (default: $DEFAULT_CONFIG_DIR)
    --verbose           Show detailed switch information
    -h, --help          Show this help message

EXAMPLES:
    $SCRIPT_NAME status                    # Full house status
    $SCRIPT_NAME status --room bedroom     # Bedroom status only
    $SCRIPT_NAME status --verbose          # Include switch details

OUTPUT:
    - System power state (ONLINE/BACKUP/CRITICAL/OFFLINE)
    - Room-by-room power status table
    - Current uptime information
    - Critical infrastructure status
    - Time since last outage
EOF
}

show_uptime_help() {
    cat << EOF
$SCRIPT_NAME uptime - Show detailed uptime information

Usage: $SCRIPT_NAME uptime [OPTIONS]

Display power uptime information for house or specific rooms.

OPTIONS:
    --room ROOM          Show uptime for specific room
    --all-rooms         Show uptime for all rooms
    --database-path PATH Database file path (default: $DEFAULT_DB_PATH)
    -h, --help          Show this help message

EXAMPLES:
    $SCRIPT_NAME uptime                  # House uptime
    $SCRIPT_NAME uptime --room bedroom   # Bedroom uptime
    $SCRIPT_NAME uptime --all-rooms      # All room uptimes

OUTPUT:
    - Current power state and duration
    - Time since last power change
    - Historical reliability statistics
    - Power mode breakdown (main vs backup time)
EOF
}

show_history_help() {
    cat << EOF
$SCRIPT_NAME history - Show outage history and analysis

Usage: $SCRIPT_NAME history [OPTIONS]

Display historical outage information and power reliability statistics.

OPTIONS:
    --room ROOM          Show history for specific room
    --all-rooms         Show history for all rooms
    --days DAYS         Number of days to include (default: 30)
    --limit COUNT       Maximum number of outages to show (default: 20)
    --database-path PATH Database file path (default: $DEFAULT_DB_PATH)
    -h, --help          Show this help message

EXAMPLES:
    $SCRIPT_NAME history                     # Recent house outages
    $SCRIPT_NAME history --days 7           # Last week
    $SCRIPT_NAME history --room server-room # Server room history
    $SCRIPT_NAME history --all-rooms        # All room histories

OUTPUT:
    - Chronological outage list
    - Outage duration and type (main power vs backup failure)
    - Affected rooms for each outage
    - Statistical summary (total outages, average duration, etc.)
    - Power reliability percentage
EOF
}

show_rooms_help() {
    cat << EOF
$SCRIPT_NAME rooms - Room management and statistics

Usage: $SCRIPT_NAME rooms <action> [OPTIONS]

Manage rooms and view room-specific power statistics.

ACTIONS:
    list            List all rooms with switch counts
    stats           Show room power statistics and reliability
    add ROOM        Add new room to configuration
    remove ROOM     Remove room from configuration

OPTIONS:
    --database-path PATH Database file path (default: $DEFAULT_DB_PATH)
    --config-dir PATH    Configuration directory (default: $DEFAULT_CONFIG_DIR)
    -h, --help          Show this help message

EXAMPLES:
    $SCRIPT_NAME rooms list              # List all rooms
    $SCRIPT_NAME rooms stats             # Room statistics
    $SCRIPT_NAME rooms add office        # Add office room
    $SCRIPT_NAME rooms remove guest-room # Remove guest room

OUTPUT:
    - Room names with switch counts
    - Current power status per room
    - Historical reliability per room
    - Switch details per room
EOF
}

show_test_help() {
    cat << EOF
$SCRIPT_NAME test - Test system functionality

Usage: $SCRIPT_NAME test [component] [OPTIONS]

Test various components of the power monitoring system.

COMPONENTS:
    config          Test configuration loading and validation
    network         Test network connectivity and MAC validation
    database        Test database operations
    power-logic     Test power state calculations
    ui              Test UI components
    all             Test all components (default)

OPTIONS:
    --config-dir PATH    Configuration directory (default: $DEFAULT_CONFIG_DIR)
    --database-path PATH Database file path (default: $DEFAULT_DB_PATH)
    --verbose           Detailed test output
    -h, --help          Show this help message

EXAMPLES:
    $SCRIPT_NAME test                # Test all components
    $SCRIPT_NAME test network        # Test network functionality
    $SCRIPT_NAME test config         # Test configuration loading
    $SCRIPT_NAME test --verbose      # Detailed test output
EOF
}

# Utility functions

parse_global_options() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --database-path)
                DB_PATH="$2"
                shift 2
                ;;
            --config-dir)
                CONFIG_DIR="$2"
                shift 2
                ;;
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE=true
                export POWER_MONITOR_DEBUG=1
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            -h|--help)
                show_main_help
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                echo "Unknown global option: $1" >&2
                exit 1
                ;;
            *)
                # Not a global option, pass it back
                break
                ;;
        esac
    done
    
    # Export configuration for library modules
    export POWER_MONITOR_DB_PATH="$DB_PATH"
    export POWER_MONITOR_CONFIG_DIR="$CONFIG_DIR"
    export POWER_MONITOR_NON_INTERACTIVE="$NON_INTERACTIVE"
    
    # Validate paths
    if [[ ! -d "$(dirname "$DB_PATH")" ]]; then
        mkdir -p "$(dirname "$DB_PATH")"
    fi
    
    if [[ ! -d "$CONFIG_DIR" ]]; then
        show_error "Configuration directory not found: $CONFIG_DIR"
        exit 1
    fi
}

check_dependencies() {
    local missing_deps=()
    
    # Check required dependencies
    command -v duckdb >/dev/null || missing_deps+=("duckdb")
    command -v ping >/dev/null || missing_deps+=("ping")
    command -v jq >/dev/null || missing_deps+=("jq")
    
    # Check for ARP command
    if ! command -v arp >/dev/null 2>&1 && ! command -v ip >/dev/null 2>&1; then
        missing_deps+=("arp or ip")
    fi
    
    # Check optional dependencies
    if ! command -v gum >/dev/null 2>&1; then
        show_warning "gum not found - UI will use fallback mode"
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        show_error "Missing required dependencies: ${missing_deps[*]}"
        echo "Please install missing dependencies before proceeding." >&2
        exit 1
    fi
    
    if [[ "$VERBOSE" == true ]]; then
        show_info "All dependencies satisfied"
    fi
}

# Subcommand implementations

cmd_init() {
    local force_init=false
    
    # Parse init-specific options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                force_init=true
                shift
                ;;
            -h|--help)
                show_init_help
                exit 0
                ;;
            *)
                echo "Unknown init option: $1" >&2
                show_init_help >&2
                exit 1
                ;;
        esac
    done
    
    show_header "Power Monitor Initialization"
    
    # Check dependencies
    echo "Checking dependencies..."
    check_dependencies
    show_success "Dependencies verified"
    
    # Initialize database
    echo "Initializing database..."
    if ! init_database "$force_init"; then
        show_error "Database initialization failed"
        exit 1
    fi
    
    # Validate and load switches configuration
    echo "Loading switch configuration..."
    local switches_config="$CONFIG_DIR/switches.json"
    
    if [[ ! -f "$switches_config" ]]; then
        show_warning "Switches configuration not found: $switches_config"
        show_info "Creating sample configuration..."
        create_sample_config "$switches_config.example"
        show_error "Please copy $switches_config.example to $switches_config and edit with your switch details"
        exit 1
    fi
    
    if ! validate_switches_config "$switches_config"; then
        show_error "Switch configuration validation failed"
        exit 1
    fi
    
    # Import switches to database
    echo "Importing switches to database..."
    local switches_data
    switches_data=$(load_switches_config "$switches_config")
    
    while IFS= read -r switch_json; do
        if [[ -z "$switch_json" || "$switch_json" == "null" ]]; then
            continue
        fi
        
        local label ip_address room_name mac_address backup_connected
        label=$(echo "$switch_json" | jq -r '.label')
        ip_address=$(echo "$switch_json" | jq -r '."ip-address" // ."ip_address"')
        room_name=$(echo "$switch_json" | jq -r '.location // .room')
        mac_address=$(echo "$switch_json" | jq -r '."mac-address" // ."mac_address"')
        backup_connected=$(echo "$switch_json" | jq -r '."backup-connected" // ."backup_connected" // false')
        
        insert_switch "$label" "$ip_address" "$room_name" "$mac_address" "$backup_connected"
        
    done < <(echo "$switches_data" | jq -c '.[]')
    
    show_success "Switch configuration imported"
    
    # Show configuration statistics
    echo
    show_section_header "Configuration Summary"
    show_config_stats "$switches_config"
    
    echo
    show_success "Power Monitor initialization completed successfully!"
    echo
    echo "Next steps:"
    echo "1. Run: $SCRIPT_NAME record    # Test switch connectivity"
    echo "2. Run: $SCRIPT_NAME status    # View power status"
    echo "3. Add to crontab for regular monitoring"
}

cmd_record() {
    local parallel_jobs=10
    
    # Parse record-specific options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --parallel)
                parallel_jobs="$2"
                shift 2
                ;;
            -h|--help)
                show_record_help
                exit 0
                ;;
            *)
                echo "Unknown record option: $1" >&2
                show_record_help >&2
                exit 1
                ;;
        esac
    done
    
    if [[ "$VERBOSE" == true ]]; then
        show_header "Power Status Recording" "Network Check & Database Update"
    fi
    
    # Check database
    if ! check_database; then
        show_error "Database not accessible. Run '$SCRIPT_NAME init' first."
        exit 1
    fi
    
    # Load switches configuration
    local switches_config="$CONFIG_DIR/switches.json"
    local switches_data
    if ! switches_data=$(load_switches_config "$switches_config"); then
        show_error "Invalid switch configuration"
        exit 1
    fi
    
    local switch_count
    switch_count=$(echo "$switches_data" | jq 'length')
    
    if [[ $switch_count -eq 0 ]]; then
        show_error "No switches configured"
        exit 1
    fi
    
    # Check switches with progress indication
    if [[ "$VERBOSE" == true ]]; then
        echo "Checking $switch_count switches..."
    fi
    
    local switch_results
    if [[ $switch_count -le 5 || "$VERBOSE" == true ]]; then
        # Sequential checking for small numbers or verbose mode
        switch_results=$(check_switches_with_progress "$switches_data" "$TIMEOUT")
    else
        # Parallel checking for better performance
        switch_results=$(check_switches_parallel "$switches_data" "$parallel_jobs" "$TIMEOUT")
    fi
    
    # Parse results and build status data
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    local combined_status='[]'
    local current_switch=""
    
    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            current_switch=""
            continue
        fi
        
        if [[ "$line" =~ ^switch_label: ]]; then
            current_switch=$(echo "$line" | cut -d: -f2)
            continue
        fi
        
        if [[ -n "$current_switch" && "$line" =~ ^ip_address: ]]; then
            local ip_address room_name mac_address backup_connected
            local ping_successful mac_validated is_authentic expected_mac actual_mac response_time
            
            ip_address=$(echo "$line" | cut -d: -f2)
            
            # Get switch config details
            local switch_config
            switch_config=$(echo "$switches_data" | jq --arg label "$current_switch" '.[] | select(.label == $label)')
            room_name=$(echo "$switch_config" | jq -r '.location // .room')
            mac_address=$(echo "$switch_config" | jq -r '."mac-address" // ."mac_address"')
            backup_connected=$(echo "$switch_config" | jq -r '."backup-connected" // ."backup_connected" // false')
            
            # Read remaining status lines for this switch
            local status_data=""
            while IFS= read -r status_line && [[ "$status_line" != "---" ]]; do
                status_data+="$status_line"$'\n'
                if [[ "$status_line" =~ ^detection_method: ]]; then
                    break
                fi
            done
            
            # Parse status data (use cut -d: -f2- to handle colons in MAC addresses)
            ping_successful=$(echo "$status_data" | grep "^ping_successful:" | cut -d: -f2)
            mac_validated=$(echo "$status_data" | grep "^mac_validated:" | cut -d: -f2)
            is_authentic=$(echo "$status_data" | grep "^is_authentic:" | cut -d: -f2)
            local alternative_method_used detection_method
            alternative_method_used=$(echo "$status_data" | grep "^alternative_method_used:" | cut -d: -f2)
            expected_mac="$mac_address"
            actual_mac=$(echo "$status_data" | grep "^actual_mac:" | cut -d: -f2-)
            response_time=$(echo "$status_data" | grep "^response_time:" | cut -d: -f2)
            detection_method=$(echo "$status_data" | grep "^detection_method:" | cut -d: -f2)
            
            # Add to combined status
            local switch_status
            switch_status=$(jq -n \
                --arg label "$current_switch" \
                --arg ip "$ip_address" \
                --arg room "$room_name" \
                --arg expected_mac "$expected_mac" \
                --arg actual_mac "$actual_mac" \
                --argjson backup_connected "$backup_connected" \
                --argjson ping_successful "$ping_successful" \
                --argjson mac_validated "$mac_validated" \
                --argjson is_authentic "$is_authentic" \
                --argjson alternative_method_used "$alternative_method_used" \
                --arg response_time "$response_time" \
                '{
                    label: $label,
                    ip_address: $ip,
                    room_name: $room,
                    backup_connected: $backup_connected,
                    ping_successful: $ping_successful,
                    mac_validated: $mac_validated,
                    is_authentic: $is_authentic,
                    alternative_method_used: $alternative_method_used,
                    expected_mac: $expected_mac,
                    actual_mac: $actual_mac,
                    response_time: $response_time
                }')
            
            combined_status=$(echo "$combined_status" | jq --argjson switch "$switch_status" '. + [$switch]')
            
            # Store individual switch status if not dry run
            if [[ "$DRY_RUN" != true ]]; then
                # Ensure switch exists in database before inserting status
                insert_switch "$current_switch" "$ip_address" "$room_name" "$expected_mac" "$backup_connected"
                
                insert_switch_status "$timestamp" "$current_switch" "$ip_address" "$room_name" \
                    "$backup_connected" "$ping_successful" "$mac_validated" "$is_authentic" \
                    "$expected_mac" "${actual_mac:-NULL}" "${response_time:-NULL}" "${detection_method:-0}"
            fi
        fi
    done <<< "$switch_results"
    
    # Calculate power status
    local power_summary
    power_summary=$(generate_power_summary "$combined_status" "$timestamp")
    
    # Parse power summary results
    local main_switches_online main_switches_total main_power_on
    local backup_switches_online backup_switches_total backup_power_on
    local system_status
    
    main_switches_online=$(echo "$power_summary" | grep "main_switches_online:" | cut -d: -f2)
    main_switches_total=$(echo "$power_summary" | grep "main_switches_total:" | cut -d: -f2)
    main_power_on=$(echo "$power_summary" | grep "main_power_on:" | cut -d: -f2)
    backup_switches_online=$(echo "$power_summary" | grep "backup_switches_online:" | cut -d: -f2)
    backup_switches_total=$(echo "$power_summary" | grep "backup_switches_total:" | cut -d: -f2)
    backup_power_on=$(echo "$power_summary" | grep "backup_power_on:" | cut -d: -f2)
    system_status=$(echo "$power_summary" | grep "system_status:" | cut -d: -f2)
    
    # Store house-level power status if not dry run
    if [[ "$DRY_RUN" != true ]]; then
        # Get previous status for outage detection
        local previous_status=""
        local current_outage_id=""
        # Use clean SQL to avoid table formatting issues
        if previous_status=$(duckdb "$DB_PATH" -noheader -list "SELECT system_status FROM power_status ORDER BY timestamp DESC LIMIT 1;" 2>/dev/null); then
            current_outage_id=$(duckdb "$DB_PATH" -noheader -list "SELECT house_outage_id FROM power_status ORDER BY timestamp DESC LIMIT 1;" 2>/dev/null)
        fi
        
        # Detect outage events
        local outage_detection
        outage_detection=$(detect_outage_events "$system_status" "$previous_status" "$current_outage_id")
        
        local house_outage_id="NULL"
        local is_outage_start
        is_outage_start=$(echo "$outage_detection" | grep "is_outage_start:" | cut -d: -f2)
        
        if [[ "$is_outage_start" == "true" ]]; then
            house_outage_id=$(get_next_outage_id)
        elif [[ -n "$current_outage_id" && "$current_outage_id" != "NULL" ]]; then
            house_outage_id="$current_outage_id"
        fi
        
        insert_power_status "$timestamp" "$main_switches_online" "$main_switches_total" \
            "$backup_switches_online" "$backup_switches_total" "$main_power_on" \
            "$backup_power_on" "$system_status" "$house_outage_id"
        
        # Store room-level power status
        local room_status
        room_status=$(echo "$power_summary" | sed -n '/room_power_status:/,$p' | tail -n +2)
        
        # Parse room data section by section
        local current_room_data=""
        local in_room_section=false
        
        while IFS= read -r line; do
            if [[ "$line" == "---" ]]; then
                # Process completed room section
                if [[ "$in_room_section" == true && -n "$current_room_data" ]]; then
                    local room_name switches_online total_switches room_power_on
                    room_name=$(echo "$current_room_data" | sed -n '/^room_name:/p' | cut -d: -f2)
                    switches_online=$(echo "$current_room_data" | sed -n '/^switches_online:/p' | cut -d: -f2)
                    total_switches=$(echo "$current_room_data" | sed -n '/^switches_total:/p' | cut -d: -f2)
                    room_power_on=$(echo "$current_room_data" | sed -n '/^room_power_on:/p' | cut -d: -f2)
                    
                    if [[ -n "$room_name" && -n "$switches_online" ]]; then
                        insert_room_power_status "$timestamp" "$room_name" "$switches_online" \
                            "$total_switches" "$room_power_on" "NULL"
                    fi
                fi
                # Reset for next room
                current_room_data=""
                in_room_section=false
                continue
            fi
            
            if [[ "$line" =~ ^room_name: ]]; then
                in_room_section=true
                current_room_data="$line"
            elif [[ "$in_room_section" == true ]]; then
                current_room_data="$current_room_data"$'\n'"$line"
            fi
        done <<< "$room_status"
        
        # Handle last room section (no trailing ---)
        if [[ "$in_room_section" == true && -n "$current_room_data" ]]; then
            local room_name switches_online total_switches room_power_on
            room_name=$(echo "$current_room_data" | sed -n '/^room_name:/p' | cut -d: -f2)
            switches_online=$(echo "$current_room_data" | sed -n '/^switches_online:/p' | cut -d: -f2)
            total_switches=$(echo "$current_room_data" | sed -n '/^switches_total:/p' | cut -d: -f2)
            room_power_on=$(echo "$current_room_data" | sed -n '/^room_power_on:/p' | cut -d: -f2)
            
            if [[ -n "$room_name" && -n "$switches_online" ]]; then
                insert_room_power_status "$timestamp" "$room_name" "$switches_online" \
                    "$total_switches" "$room_power_on" "NULL"
            fi
        fi
    fi
    
    # Show results
    if [[ "$VERBOSE" == true || "$DRY_RUN" == true ]]; then
        echo
        show_section_header "Power Status Summary"
        
        echo "System Status: $(format_power_status "$system_status")"
        echo "Main Power: $main_switches_online/$main_switches_total switches online ($main_power_on)"
        echo "Backup Power: $backup_switches_online/$backup_switches_total switches online ($backup_power_on)"
        echo "Timestamp: $timestamp"
        
        if [[ "$DRY_RUN" == true ]]; then
            show_warning "DRY RUN - No data stored in database"
        else
            show_success "Power status recorded successfully"
        fi
    fi
}

cmd_status() {
    local target_room=""
    local show_switches=false
    
    # Parse status-specific options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --room)
                target_room="$2"
                shift 2
                ;;
            --verbose)
                show_switches=true
                shift
                ;;
            -h|--help)
                show_status_help
                exit 0
                ;;
            *)
                echo "Unknown status option: $1" >&2
                show_status_help >&2
                exit 1
                ;;
        esac
    done
    
    # Check database
    if ! check_database; then
        show_error "Database not accessible. Run '$SCRIPT_NAME init' first."
        exit 1
    fi
    
    # Get current power status
    local current_status
    if ! current_status=$(get_current_power_status 2>/dev/null); then
        show_error "No power status data found. Run '$SCRIPT_NAME record' first."
        exit 1
    fi
    
    # Parse current status
    local timestamp system_status main_power_on backup_power_on
    local main_switches_online main_switches_total backup_switches_online backup_switches_total
    
    # Clean output format: timestamp|system_status|main_power_on|backup_power_on|main_switches_online|main_switches_total|backup_switches_online|backup_switches_total|main_power_percentage|backup_power_percentage
    timestamp=$(echo "$current_status" | cut -d'|' -f1)
    system_status=$(echo "$current_status" | cut -d'|' -f2)
    main_power_on=$(echo "$current_status" | cut -d'|' -f3)
    backup_power_on=$(echo "$current_status" | cut -d'|' -f4)
    main_switches_online=$(echo "$current_status" | cut -d'|' -f5)
    main_switches_total=$(echo "$current_status" | cut -d'|' -f6)
    backup_switches_online=$(echo "$current_status" | cut -d'|' -f7)
    backup_switches_total=$(echo "$current_status" | cut -d'|' -f8)
    
    # Calculate uptime
    local uptime_info=""
    if uptime_data=$(get_current_uptime "house"); then
        # Parse clean output: system_status|timestamp|uptime_minutes
        local uptime_minutes
        uptime_minutes=$(echo "$uptime_data" | cut -d'|' -f3)
        if [[ -n "$uptime_minutes" && "$uptime_minutes" != "NULL" ]]; then
            uptime_info=$(format_uptime_minutes "$uptime_minutes")
        fi
    fi
    
    # Show header
    local subtitle=""
    case "$system_status" in
        "BACKUP") subtitle="House & Room Status [BACKUP]" ;;
        "CRITICAL") subtitle="House & Room Status [CRITICAL]" ;;
        "OFFLINE") subtitle="House & Room Status [OFFLINE]" ;;
        *) subtitle="House & Room Status" ;;
    esac
    
    show_header "Power Monitor" "$subtitle"
    
    # Show system status
    show_system_status "$system_status" "$uptime_info"
    
    # Get room status
    local room_status
    if [[ -n "$target_room" ]]; then
        room_status=$(get_current_room_status "$target_room")
    else
        room_status=$(get_current_room_status)
    fi
    
    if [[ -n "$room_status" ]]; then
        show_section_header "Room Status"
        
        # Format room data for table
        local room_table_data=""
        
        while IFS='|' read -r room_name switches_online total_switches room_power_on last_update power_percentage; do
            [[ -z "$room_name" ]] && continue
            
            local switches_display="$switches_online/$total_switches"
            local status_display
            local uptime_display="--"
            local backup_display="No"
            
            # Determine room status
            if [[ "$room_power_on" == "true" ]]; then
                if [[ $switches_online -eq $total_switches ]]; then
                    status_display="ONLINE"
                else
                    status_display="PARTIAL"
                fi
            else
                status_display="OFFLINE"
            fi
            
            # Check if room has backup switches by querying the switches directly
            local backup_switches
            backup_switches=$(duckdb "$DB_PATH" -noheader -list "SELECT COUNT(*) FROM switches WHERE room_name = '$room_name' AND backup_connected = true;" 2>/dev/null)
            if [[ $backup_switches -gt 0 ]]; then
                backup_display="Yes"
            fi
            
            # Calculate room uptime
            if room_uptime=$(get_current_uptime "room" "$room_name" 2>/dev/null); then
                # Parse clean output: room_name|room_power_on|timestamp|uptime_minutes
                local uptime_minutes
                uptime_minutes=$(echo "$room_uptime" | cut -d'|' -f4)
                if [[ -n "$uptime_minutes" && "$uptime_minutes" != "NULL" ]]; then
                    uptime_display=$(format_uptime_minutes "$uptime_minutes")
                fi
            fi
            
            room_table_data+="$room_name"$'\t'"$switches_display"$'\t'"$status_display"$'\t'"$uptime_display"$'\t'"$backup_display"$'\n'
            
        done <<< "$room_status"
        
        create_room_status_table "$room_table_data"
    fi
    
    # Show backup infrastructure status
    if [[ $backup_switches_total -gt 0 ]]; then
        echo
        show_section_header "Critical Infrastructure"
        if [[ "$backup_power_on" == "true" ]]; then
            echo -n "Status: "
            format_status_online "OPERATIONAL"
            echo " - All backup systems online ($backup_switches_online/$backup_switches_total)"
        else
            echo -n "Status: "
            format_status_critical "FAILED"
            echo " - Backup system failure detected ($backup_switches_online/$backup_switches_total)"
        fi
    fi
    
    # Show switch details if requested
    if [[ "$show_switches" == true ]]; then
        echo
        show_section_header "Switch Details"
        
        local switch_status
        if [[ -n "$target_room" ]]; then
            switch_status=$(get_current_switch_status "" "$target_room")
        else
            switch_status=$(get_current_switch_status)
        fi
        
        if [[ -n "$switch_status" ]]; then
            local switch_table_data=""
            
            while IFS='|' read -r label ip_address room_name mac_address backup_connected ping_successful mac_validated is_authentic actual_mac response_time last_check; do
                [[ -z "$label" ]] && continue
                
                local status_display="OFFLINE"
                local response_display="--"
                local backup_display="No"
                
                if [[ "$is_authentic" == "true" ]]; then
                    status_display="ONLINE"
                    if [[ -n "$response_time" && "$response_time" != "null" ]]; then
                        response_display="${response_time}ms"
                    fi
                fi
                
                if [[ "$backup_connected" == "true" ]]; then
                    backup_display="Yes"
                fi
                
                switch_table_data+="$label"$'\t'"$ip_address"$'\t'"$room_name"$'\t'"$status_display"$'\t'"$response_display"$'\t'"$backup_display"$'\n'
                
            done <<< "$switch_status"
            
            create_switch_status_table "$switch_table_data"
        fi
    fi
    
    echo
    echo "Last updated: $timestamp"
    
    if [[ "$system_status" == "CRITICAL" ]]; then
        echo
        show_error "CRITICAL: Backup power system failure detected!"
        echo "The monitoring system may be at risk."
    fi
}

cmd_uptime() {
    local target_room=""
    local all_rooms=false
    
    # Parse uptime-specific options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --room)
                target_room="$2"
                shift 2
                ;;
            --all-rooms)
                all_rooms=true
                shift
                ;;
            -h|--help)
                show_uptime_help
                exit 0
                ;;
            *)
                echo "Unknown uptime option: $1" >&2
                show_uptime_help >&2
                exit 1
                ;;
        esac
    done
    
    # Check database
    if ! check_database; then
        show_error "Database not accessible. Run '$SCRIPT_NAME init' first."
        exit 1
    fi
    
    show_header "Power Uptime Information"
    
    # House uptime
    if [[ -z "$target_room" ]]; then
        show_section_header "House Uptime"
        
        if uptime_data=$(get_current_uptime "house" 2>/dev/null); then
            # Parse clean output: system_status|timestamp|uptime_minutes
            local current_status timestamp uptime_minutes
            current_status=$(echo "$uptime_data" | cut -d'|' -f1)
            timestamp=$(echo "$uptime_data" | cut -d'|' -f2)
            uptime_minutes=$(echo "$uptime_data" | cut -d'|' -f3)
            
            echo -n "Current Status: "
            format_power_status "$current_status"
            echo
            
            local formatted_uptime=$(format_uptime_minutes "$uptime_minutes")
            if [[ "$current_status" == "ONLINE" ]]; then
                echo "Power Uptime: $formatted_uptime (since $timestamp)"
            else
                echo "Power Outage Duration: $formatted_uptime (since $timestamp)"
            fi
        else
            show_warning "No uptime data available"
        fi
        
        # Show reliability stats
        if reliability_data=$(get_system_reliability 2>/dev/null); then
            echo
            local online_percentage backup_percentage total_hours
            online_percentage=$(echo "$reliability_data" | cut -d'|' -f8)
            backup_percentage=$(echo "$reliability_data" | cut -d'|' -f9)
            total_hours=$(echo "$reliability_data" | cut -d'|' -f12)
            
            echo "Reliability Statistics:"
            echo "  Online: ${online_percentage}%"
            echo "  Backup: ${backup_percentage}%"
            echo "  Monitored: ${total_hours}h total"
        fi
    fi
    
    # Room uptime
    if [[ -n "$target_room" ]] || [[ "$all_rooms" == true ]]; then
        if [[ -n "$target_room" ]]; then
            show_section_header "Room Uptime: $target_room"
            local rooms=("$target_room")
        else
            show_section_header "All Room Uptimes"
            local rooms
            mapfile -t rooms < <(get_rooms 2>/dev/null)
        fi
        
        for room in "${rooms[@]}"; do
            [[ -z "$room" ]] && continue
            
            if [[ "$all_rooms" == true ]]; then
                echo
                echo "Room: $room"
                echo "────────────────"
            fi
            
            if room_uptime_data=$(get_room_uptime_stats "$room" 2>/dev/null); then
                local uptime_percentage total_hours
                uptime_percentage=$(echo "$room_uptime_data" | tail -1 | cut -d'|' -f6)
                total_hours=$(echo "$room_uptime_data" | tail -1 | cut -d'|' -f7)
                
                echo "Room Reliability: ${uptime_percentage}%"
                echo "Monitored Hours: ${total_hours}h"
                
                # Get current room status
                if room_status=$(get_current_room_status "$room" 2>/dev/null); then
                    local room_power_on last_update
                    room_power_on=$(echo "$room_status" | tail -1 | cut -d'|' -f4)
                    last_update=$(echo "$room_status" | tail -1 | cut -d'|' -f5)
                    
                    if [[ "$room_power_on" == "true" ]]; then
                        echo -n "Current Status: "
                        format_status_online "ONLINE"
                        echo " since $last_update"
                    else
                        echo -n "Current Status: "
                        format_status_offline "OFFLINE"
                        echo " since $last_update"
                    fi
                fi
            else
                show_warning "No uptime data available for $room"
            fi
        done
    fi
}

cmd_history() {
    local target_room=""
    local all_rooms=false
    local days=30
    local limit=20
    
    # Parse history-specific options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --room)
                target_room="$2"
                shift 2
                ;;
            --all-rooms)
                all_rooms=true
                shift
                ;;
            --days)
                days="$2"
                shift 2
                ;;
            --limit)
                limit="$2"
                shift 2
                ;;
            -h|--help)
                show_history_help
                exit 0
                ;;
            *)
                echo "Unknown history option: $1" >&2
                show_history_help >&2
                exit 1
                ;;
        esac
    done
    
    # Check database
    if ! check_database; then
        show_error "Database not accessible. Run '$SCRIPT_NAME init' first."
        exit 1
    fi
    
    show_header "Power History & Outage Analysis"
    
    # Show recent outages
    show_section_header "Recent Outages (Last $days days)"
    
    if outage_data=$(get_outage_summary "$limit" 2>/dev/null); then
        local outage_table_data=""
        
        while IFS='|' read -r outage_id system_status outage_start outage_end duration_records duration_minutes; do
            [[ -z "$outage_id" ]] && continue
            
            local start_display end_display duration_display type_display
            start_display=$(date -d "$outage_start" '+%m/%d %H:%M' 2>/dev/null || echo "$outage_start")
            end_display=$(date -d "$outage_end" '+%m/%d %H:%M' 2>/dev/null || echo "$outage_end")
            
            # Format duration
            if [[ -n "$duration_minutes" ]] && [[ "$duration_minutes" != "null" ]]; then
                local hours minutes
                hours=$((${duration_minutes%.*} / 60))
                minutes=$((${duration_minutes%.*} % 60))
                if [[ $hours -gt 0 ]]; then
                    duration_display="${hours}h ${minutes}m"
                else
                    duration_display="${minutes}m"
                fi
            else
                duration_display="--"
            fi
            
            type_display="$system_status"
            
            outage_table_data+="$start_display"$'\t'"$end_display"$'\t'"$duration_display"$'\t'"$type_display"$'\t'"All"$'\n'
            
        done <<< "$outage_data"
        
        if [[ -n "$outage_table_data" ]]; then
            create_outage_history_table "$outage_table_data"
        else
            echo "No outages recorded in the last $days days"
        fi
    else
        echo "No outage data available"
    fi
    
    # Show power status history
    echo
    show_section_header "Power Status History"
    
    if power_history=$(get_power_status_history "$limit" "$days" 2>/dev/null); then
        echo "Recent power state changes:"
        echo
        printf "%-16s %-8s %-8s %-8s\n" "Timestamp" "Status" "Main" "Backup"
        printf "%-16s %-8s %-8s %-8s\n" "────────────────" "────────" "────────" "────────"
        
        while IFS='|' read -r timestamp system_status main_power_on backup_power_on main_online main_total backup_online backup_total; do
            [[ -z "$timestamp" ]] && continue
            
            local time_display main_display backup_display
            time_display=$(date -d "$timestamp" '+%m/%d %H:%M' 2>/dev/null || echo "${timestamp:0:16}")
            main_display="$main_online/$main_total"
            backup_display="$backup_online/$backup_total"
            
            printf "%-16s " "$time_display"
            printf "%-8s " "$(format_power_status "$system_status")"
            printf "%-8s %-8s\n" "$main_display" "$backup_display"
            
        done <<< "$power_history"
    fi
    
    # Show statistics
    echo
    show_section_header "Statistics"
    
    if reliability_data=$(get_system_reliability 2>/dev/null); then
        local total_records online_records backup_records critical_records offline_records
        local online_pct backup_pct critical_pct offline_pct total_hours
        
        total_records=$(echo "$reliability_data" | tail -1 | cut -d'|' -f1)
        online_records=$(echo "$reliability_data" | tail -1 | cut -d'|' -f2)
        backup_records=$(echo "$reliability_data" | tail -1 | cut -d'|' -f3)
        critical_records=$(echo "$reliability_data" | tail -1 | cut -d'|' -f4)
        offline_records=$(echo "$reliability_data" | tail -1 | cut -d'|' -f5)
        online_pct=$(echo "$reliability_data" | tail -1 | cut -d'|' -f9)
        backup_pct=$(echo "$reliability_data" | tail -1 | cut -d'|' -f10)
        critical_pct=$(echo "$reliability_data" | tail -1 | cut -d'|' -f11)
        offline_pct=$(echo "$reliability_data" | tail -1 | cut -d'|' -f12)
        total_hours=$(echo "$reliability_data" | tail -1 | cut -d'|' -f14)
        
        echo "Overall Reliability:"
        echo "  Total Records: $total_records"
        echo "  Online Time: ${online_pct}% ($online_records records)"
        echo "  Backup Time: ${backup_pct}% ($backup_records records)"
        echo "  Critical Events: ${critical_pct}% ($critical_records records)"
        echo "  Offline Time: ${offline_pct}% ($offline_records records)"
        echo "  Monitoring Period: ${total_hours}h"
    fi
}

cmd_rooms() {
    local action="list"
    
    # Parse rooms-specific options
    if [[ $# -gt 0 ]]; then
        action="$1"
        shift
    fi
    
    case "$action" in
        list|stats|add|remove)
            ;;
        -h|--help)
            show_rooms_help
            exit 0
            ;;
        *)
            echo "Unknown rooms action: $action" >&2
            show_rooms_help >&2
            exit 1
            ;;
    esac
    
    # Check database
    if ! check_database; then
        show_error "Database not accessible. Run '$SCRIPT_NAME init' first."
        exit 1
    fi
    
    case "$action" in
        list)
            show_header "Room Management" "List All Rooms"
            
            if room_status=$(get_current_room_status 2>/dev/null); then
                local room_table_data=""
                
                while IFS='|' read -r room_name switches_online total_switches room_power_on last_update power_percentage; do
                    [[ -z "$room_name" ]] && continue
                    
                    local switches_display="$switches_online/$total_switches"
                    local status_display
                    
                    if [[ "$room_power_on" == "true" ]]; then
                        if [[ $switches_online -eq $total_switches ]]; then
                            status_display="ONLINE"
                        else
                            status_display="PARTIAL"
                        fi
                    else
                        status_display="OFFLINE"
                    fi
                    
                    # Check backup switches
                    local backup_count
                    backup_count=$(get_switches_in_room "$room_name" 2>/dev/null | jq -r '.[] | select(."backup-connected" == true or ."backup_connected" == true) | .label' 2>/dev/null | wc -l)
                    local backup_display="$backup_count"
                    
                    room_table_data+="$room_name"$'\t'"$switches_display"$'\t'"$status_display"$'\t'"$power_percentage%"$'\t'"$backup_display"$'\n'
                    
                done <<< "$room_status"
                
                if [[ -n "$room_table_data" ]]; then
                    echo "$room_table_data" | gum table \
                        --columns "Room,Switches,Status,Reliability,Backup Switches" \
                        --widths "15,10,8,12,15" \
                        --height 10 2>/dev/null || {
                        echo
                        printf "%-15s %-10s %-8s %-12s %-15s\n" "Room" "Switches" "Status" "Reliability" "Backup Switches"
                        printf "%-15s %-10s %-8s %-12s %-15s\n" "───────────────" "──────────" "────────" "────────────" "───────────────"
                        while IFS=$'\t' read -r room switches status reliability backup; do
                            printf "%-15s %-10s %-8s %-12s %-15s\n" "$room" "$switches" "$status" "$reliability" "$backup"
                        done <<< "$room_table_data"
                        echo
                    }
                fi
            else
                echo "No room data available"
            fi
            ;;
            
        stats)
            show_header "Room Statistics" "Power Reliability by Room"
            
            if room_stats=$(get_room_uptime_stats 2>/dev/null); then
                while IFS='|' read -r room_name total_records uptime_records first_record last_record uptime_percentage total_hours; do
                    [[ -z "$room_name" ]] && continue
                    
                    echo
                    show_section_header "$room_name"
                    echo "Uptime: ${uptime_percentage}%"
                    echo "Records: $uptime_records/$total_records"
                    echo "Monitored: ${total_hours}h"
                    echo "Period: $first_record to $last_record"
                    
                done <<< "$room_stats"
            else
                echo "No room statistics available"
            fi
            ;;
            
        add)
            local room_name="$1"
            if [[ -z "$room_name" ]]; then
                echo "Usage: $SCRIPT_NAME rooms add <room_name>" >&2
                exit 1
            fi
            
            insert_room "$room_name"
            show_success "Room '$room_name' added"
            ;;
            
        remove)
            local room_name="$1"
            if [[ -z "$room_name" ]]; then
                echo "Usage: $SCRIPT_NAME rooms remove <room_name>" >&2
                exit 1
            fi
            
            if confirm_action "Remove room '$room_name' and all associated data?"; then
                # This would need additional database operations to safely remove room data
                show_warning "Room removal not yet implemented"
                show_info "This feature requires careful handling of foreign key relationships"
            else
                show_info "Room removal cancelled"
            fi
            ;;
    esac
}

cmd_test() {
    local component="all"
    
    # Parse test-specific options
    while [[ $# -gt 0 ]]; do
        case $1 in
            config|network|database|power-logic|ui|all)
                component="$1"
                shift
                ;;
            -h|--help)
                show_test_help
                exit 0
                ;;
            *)
                echo "Unknown test option: $1" >&2
                show_test_help >&2
                exit 1
                ;;
        esac
    done
    
    show_header "Power Monitor System Test" "Component: $component"
    
    local test_failed=false
    
    if [[ "$component" == "all" || "$component" == "config" ]]; then
        show_section_header "Configuration Test"
        
        echo "Testing configuration loading..."
        if check_config_dependencies && validate_switches_config "$CONFIG_DIR/switches.json"; then
            show_success "Configuration test passed"
            if [[ "$VERBOSE" == true ]]; then
                show_config_stats "$CONFIG_DIR/switches.json"
            fi
        else
            show_error "Configuration test failed"
            test_failed=true
        fi
        echo
    fi
    
    if [[ "$component" == "all" || "$component" == "network" ]]; then
        show_section_header "Network Test"
        
        echo "Testing network dependencies..."
        if check_network_dependencies; then
            show_success "Network dependencies available"
            
            echo "Testing network connectivity..."
            test_network_connectivity
            
            if [[ "$VERBOSE" == true ]]; then
                echo
                echo "ARP table sample:"
                show_arp_table | head -5
            fi
        else
            show_error "Network test failed"
            test_failed=true
        fi
        echo
    fi
    
    if [[ "$component" == "all" || "$component" == "database" ]]; then
        show_section_header "Database Test"
        
        echo "Testing database operations..."
        if check_duckdb && check_database; then
            show_success "Database accessible"
            
            if db_stats=$(get_database_stats 2>/dev/null); then
                echo "Database statistics:"
                while IFS='|' read -r table_name record_count; do
                    [[ -z "$table_name" ]] && continue
                    echo "  $table_name: $record_count records"
                done <<< "$db_stats"
            fi
        else
            show_error "Database test failed"
            test_failed=true
        fi
        echo
    fi
    
    if [[ "$component" == "all" || "$component" == "power-logic" ]]; then
        show_section_header "Power Logic Test"
        
        echo "Testing power logic calculations..."
        if test_power_logic >/dev/null 2>&1; then
            show_success "Power logic test passed"
        else
            show_error "Power logic test failed"
            test_failed=true
        fi
        echo
    fi
    
    if [[ "$component" == "all" || "$component" == "ui" ]]; then
        show_section_header "UI Test"
        
        echo "Testing UI components..."
        if check_gum_available; then
            show_success "Gum available - full UI features enabled"
        else
            show_warning "Gum not available - using fallback UI mode"
        fi
        
        if [[ "$VERBOSE" == true ]]; then
            test_ui_components
        fi
        echo
    fi
    
    # Overall test result
    if [[ "$test_failed" == true ]]; then
        show_error "Some tests failed - system may not function correctly"
        exit 1
    else
        show_success "All tests passed - system ready for use"
    fi
}

# Main execution

main() {
    # Parse global options first
    parse_global_options "$@"
    
    # Skip processed global options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --database-path|--config-dir|--timeout)
                shift 2
                ;;
            --verbose|--dry-run)
                shift
                ;;
            -h|--help)
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                shift
                ;;
            *)
                break
                ;;
        esac
    done
    
    # Get subcommand
    local subcommand="${1:-}"
    if [[ -z "$subcommand" ]]; then
        show_main_help
        exit 0
    fi
    shift
    
    # Execute subcommand
    case "$subcommand" in
        init)
            cmd_init "$@"
            ;;
        record)
            cmd_record "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        uptime)
            cmd_uptime "$@"
            ;;
        history)
            cmd_history "$@"
            ;;
        rooms)
            cmd_rooms "$@"
            ;;
        test)
            cmd_test "$@"
            ;;
        -h|--help)
            show_main_help
            exit 0
            ;;
        *)
            echo "Unknown subcommand: $subcommand" >&2
            echo "Run '$SCRIPT_NAME --help' for usage information." >&2
            exit 1
            ;;
    esac
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi