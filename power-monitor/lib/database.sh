#!/bin/bash

# database.sh - DuckDB operations and abstractions for power monitoring
# This module provides database abstraction layer for easy migration to time-series databases

set -euo pipefail

# Default database path
DEFAULT_DB_PATH="$HOME/Documents/power.db"
DB_PATH="${POWER_MONITOR_DB_PATH:-$DEFAULT_DB_PATH}"

# Script directory for SQL files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQL_DIR="$SCRIPT_DIR/sql"

# Colors for output (fallback if not defined)
RED=${RED:-'\033[0;31m'}
GREEN=${GREEN:-'\033[0;32m'}
YELLOW=${YELLOW:-'\033[1;33m'}
BLUE=${BLUE:-'\033[0;34m'}
NC=${NC:-'\033[0m'}

# Dependency check
check_duckdb() {
    if ! command -v duckdb >/dev/null 2>&1; then
        echo -e "${RED}Error: duckdb is not installed${NC}" >&2
        echo "Please install duckdb: https://duckdb.org/docs/installation/" >&2
        return 1
    fi
}

# Execute DuckDB command with error handling
execute_sql() {
    local sql="$1"
    local description="${2:-SQL query}"
    
    check_duckdb || return 1
    
    if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
        echo -e "${BLUE}[DEBUG] Executing: $description${NC}" >&2
        echo -e "${BLUE}[DEBUG] SQL: $sql${NC}" >&2
    fi
    
    if ! duckdb "$DB_PATH" "$sql" 2>/dev/null; then
        echo -e "${RED}Error executing $description${NC}" >&2
        return 1
    fi
}

# Execute SQL file
execute_sql_file() {
    local sql_file="$1"
    local description="${2:-SQL file}"
    
    if [[ ! -f "$sql_file" ]]; then
        echo -e "${RED}Error: SQL file not found: $sql_file${NC}" >&2
        return 1
    fi
    
    check_duckdb || return 1
    
    if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
        echo -e "${BLUE}[DEBUG] Executing file: $sql_file${NC}" >&2
    fi
    
    if ! duckdb "$DB_PATH" < "$sql_file" 2>/dev/null; then
        echo -e "${RED}Error executing $description${NC}" >&2
        return 1
    fi
}

# Execute SQL and return clean values (without table formatting)
execute_sql_clean() {
    local sql="$1"
    local description="${2:-SQL execution}"
    
    check_database || return 1
    
    if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
        echo -e "${BLUE}[DEBUG] SQL: $sql${NC}" >&2
    fi
    
    # Use DuckDB with -noheader and -list for clean output
    if ! duckdb "$DB_PATH" -noheader -list "$sql" 2>/dev/null; then
        echo -e "${RED}Error executing $description${NC}" >&2
        return 1
    fi
}

# Initialize database with schema
init_database() {
    local force_init="${1:-false}"
    
    echo -e "${BLUE}Initializing database at: $DB_PATH${NC}"
    
    # Create database directory if it doesn't exist
    local db_dir
    db_dir="$(dirname "$DB_PATH")"
    mkdir -p "$db_dir"
    
    # If force init, remove existing database
    if [[ "$force_init" == "true" ]] && [[ -f "$DB_PATH" ]]; then
        echo -e "${YELLOW}Removing existing database (force init)${NC}"
        rm -f "$DB_PATH"
    fi
    
    # Execute schema initialization
    if ! execute_sql_file "$SQL_DIR/init.sql" "database schema initialization"; then
        echo -e "${RED}Failed to initialize database schema${NC}" >&2
        return 1
    fi
    
    echo -e "${GREEN}Database initialized successfully${NC}"
}

# Check if database exists and is accessible
check_database() {
    if [[ ! -f "$DB_PATH" ]]; then
        echo -e "${YELLOW}Database not found at: $DB_PATH${NC}" >&2
        echo "Run 'power-monitor.sh init' to initialize the database" >&2
        return 1
    fi
    
    # Test database access
    if ! execute_sql "SELECT 1;" "database connectivity test" >/dev/null; then
        echo -e "${RED}Cannot access database at: $DB_PATH${NC}" >&2
        return 1
    fi
    
    return 0
}

# Insert room record
insert_room() {
    local room_name="$1"
    
    check_database || return 1
    
    local sql="INSERT INTO rooms (room_name) VALUES ('$room_name') ON CONFLICT (room_name) DO NOTHING;"
    execute_sql "$sql" "insert room: $room_name"
}

# Insert switch record
insert_switch() {
    local label="$1"
    local ip_address="$2"
    local room_name="$3"
    local mac_address="$4"
    local backup_connected="${5:-false}"
    
    check_database || return 1
    
    # Ensure room exists first
    insert_room "$room_name"
    
    local sql="INSERT OR REPLACE INTO switches (label, ip_address, room_name, mac_address, backup_connected, first_seen) 
               VALUES ('$label', '$ip_address', '$room_name', '$mac_address', $backup_connected, CURRENT_TIMESTAMP);"
    execute_sql "$sql" "insert/update switch: $label"
}

# Insert power status record
insert_power_status() {
    local timestamp="$1"
    local main_switches_online="$2"
    local main_switches_total="$3"
    local backup_switches_online="$4"
    local backup_switches_total="$5"
    local main_power_on="$6"
    local backup_power_on="$7"
    local system_status="$8"
    local house_outage_id="${9:-NULL}"
    
    check_database || return 1
    
    local sql="INSERT OR REPLACE INTO power_status 
               (timestamp, main_power_switches_online, main_power_switches_total, 
                backup_switches_online, backup_switches_total, main_power_on, 
                backup_power_on, system_status, house_outage_id)
               VALUES ('$timestamp', $main_switches_online, $main_switches_total, 
                       $backup_switches_online, $backup_switches_total, $main_power_on, 
                       $backup_power_on, '$system_status', $house_outage_id);"
    execute_sql "$sql" "insert power status"
}

# Insert room power status record
insert_room_power_status() {
    local timestamp="$1"
    local room_name="$2"
    local switches_online="$3"
    local total_switches="$4"
    local room_power_on="$5"
    local room_outage_id="${6:-NULL}"
    
    check_database || return 1
    
    local sql="INSERT OR REPLACE INTO room_power_status 
               (timestamp, room_name, switches_online, total_switches, room_power_on, room_outage_id)
               VALUES ('$timestamp', '$room_name', $switches_online, $total_switches, $room_power_on, $room_outage_id);"
    execute_sql "$sql" "insert room power status: $room_name"
}

# Insert switch status record
insert_switch_status() {
    local timestamp="$1"
    local switch_label="$2"
    local ip_address="$3"
    local room_name="$4"
    local backup_connected="$5"
    local ping_successful="$6"
    local mac_validated="$7"
    local is_authentic="$8"
    local expected_mac="$9"
    local actual_mac="${10:-NULL}"
    local response_time_ms="${11:-NULL}"
    local detection_method="${12:-0}"
    
    check_database || return 1
    
    # Ensure room exists first
    insert_room "$room_name"
    
    # Note: We should also ensure switch exists, but we need more switch config data
    # This suggests the architecture needs improvement to pass full switch config
    
    # Handle NULL values properly
    local actual_mac_sql="NULL"
    local response_time_sql="NULL"
    
    if [[ "$actual_mac" != "NULL" && -n "$actual_mac" ]]; then
        actual_mac_sql="'$actual_mac'"
    fi
    
    if [[ "$response_time_ms" != "NULL" && -n "$response_time_ms" ]]; then
        response_time_sql="$response_time_ms"
    fi
    
    local sql="INSERT INTO switch_status 
               (timestamp, switch_label, ip_address, room_name, backup_connected, 
                ping_successful, mac_validated, is_authentic, expected_mac, actual_mac, response_time_ms, detection_method)
               VALUES ('$timestamp', '$switch_label', '$ip_address', '$room_name', $backup_connected,
                       $ping_successful, $mac_validated, $is_authentic, '$expected_mac', $actual_mac_sql, $response_time_sql, $detection_method);"
    execute_sql "$sql" "insert switch status: $switch_label"
}

# Get current power status
get_current_power_status() {
    check_database || return 1
    
    local sql="SELECT * FROM current_power_status;"
    execute_sql_clean "$sql" "get current power status"
}

# Get current room status
get_current_room_status() {
    local room_name="${1:-}"
    
    check_database || return 1
    
    local sql="SELECT * FROM current_room_status"
    if [[ -n "$room_name" ]]; then
        sql="$sql WHERE room_name = '$room_name'"
    fi
    sql="$sql ORDER BY room_name;"
    
    execute_sql_clean "$sql" "get current room status"
}

# Get current switch status
get_current_switch_status() {
    local switch_label="${1:-}"
    local room_name="${2:-}"
    
    check_database || return 1
    
    local sql="SELECT * FROM current_switch_status"
    local conditions=()
    
    if [[ -n "$switch_label" ]]; then
        conditions+=("label = '$switch_label'")
    fi
    
    if [[ -n "$room_name" ]]; then
        conditions+=("room_name = '$room_name'")
    fi
    
    if [[ ${#conditions[@]} -gt 0 ]]; then
        sql="$sql WHERE $(IFS=' AND '; echo "${conditions[*]}")"
    fi
    
    sql="$sql ORDER BY room_name, label;"
    
    execute_sql_clean "$sql" "get current switch status"
}

# Get list of all rooms
get_rooms() {
    check_database || return 1
    
    local sql="SELECT room_name FROM rooms ORDER BY room_name;"
    execute_sql "$sql" "get rooms list"
}

# Get list of switches in a room
get_switches_in_room() {
    local room_name="$1"
    
    check_database || return 1
    
    local sql="SELECT label, ip_address, mac_address, backup_connected FROM switches 
               WHERE room_name = '$room_name' ORDER BY label;"
    execute_sql "$sql" "get switches in room: $room_name"
}

# Get backup-connected switches
get_backup_switches() {
    check_database || return 1
    
    local sql="SELECT label, ip_address, room_name, mac_address FROM switches 
               WHERE backup_connected = true ORDER BY room_name, label;"
    execute_sql "$sql" "get backup-connected switches"
}

# Get non-backup switches
get_main_power_switches() {
    check_database || return 1
    
    local sql="SELECT label, ip_address, room_name, mac_address FROM switches 
               WHERE backup_connected = false ORDER BY room_name, label;"
    execute_sql "$sql" "get main power switches"
}

# Get power status history
get_power_status_history() {
    local limit="${1:-50}"
    local days="${2:-30}"
    
    check_database || return 1
    
    local sql="SELECT timestamp, system_status, main_power_on, backup_power_on, 
                      main_power_switches_online, main_power_switches_total,
                      backup_switches_online, backup_switches_total
               FROM power_status 
               WHERE timestamp >= datetime('now', '-$days days')
               ORDER BY timestamp DESC 
               LIMIT $limit;"
    execute_sql "$sql" "get power status history"
}

# Get outage summary
get_outage_summary() {
    local limit="${1:-20}"
    
    check_database || return 1
    
    local sql="SELECT * FROM outage_summary ORDER BY outage_start DESC LIMIT $limit;"
    execute_sql "$sql" "get outage summary"
}

# Get system reliability stats
get_system_reliability() {
    check_database || return 1
    
    local sql="SELECT * FROM system_reliability;"
    execute_sql_clean "$sql" "get system reliability"
}

# Get room uptime statistics
get_room_uptime_stats() {
    local room_name="${1:-}"
    
    check_database || return 1
    
    local sql="SELECT * FROM room_uptime_stats"
    if [[ -n "$room_name" ]]; then
        sql="$sql WHERE room_name = '$room_name'"
    fi
    sql="$sql ORDER BY room_name;"
    
    execute_sql_clean "$sql" "get room uptime stats"
}

# Calculate current uptime
get_current_uptime() {
    local power_type="${1:-house}" # house, room, or specific room name
    local room_name="${2:-}"
    
    check_database || return 1
    
    local sql
    case "$power_type" in
        "house")
            # Find the last time the system status changed
            sql="WITH status_changes AS (
                    SELECT 
                        system_status,
                        timestamp,
                        LAG(system_status) OVER (ORDER BY timestamp) as prev_status
                    FROM power_status 
                    ORDER BY timestamp DESC
                ),
                last_change AS (
                    SELECT 
                        system_status,
                        timestamp as change_timestamp
                    FROM status_changes 
                    WHERE system_status != prev_status OR prev_status IS NULL
                    ORDER BY timestamp DESC
                    LIMIT 1
                )
                SELECT 
                    lc.system_status,
                    lc.change_timestamp as current_since,
                    ROUND(EXTRACT('epoch' FROM (CURRENT_TIMESTAMP - lc.change_timestamp::timestamp)) / 60, 1) as uptime_minutes
                FROM last_change lc;"
            ;;
        "room")
            if [[ -z "$room_name" ]]; then
                echo -e "${RED}Room name required for room uptime calculation${NC}" >&2
                return 1
            fi
            # Find the last time the room power status changed
            sql="WITH room_status_changes AS (
                    SELECT 
                        room_name,
                        room_power_on,
                        timestamp,
                        LAG(room_power_on) OVER (ORDER BY timestamp) as prev_power_on
                    FROM room_power_status 
                    WHERE room_name = '$room_name'
                    ORDER BY timestamp DESC
                ),
                last_room_change AS (
                    SELECT 
                        room_name,
                        room_power_on,
                        timestamp as change_timestamp
                    FROM room_status_changes 
                    WHERE room_power_on != prev_power_on OR prev_power_on IS NULL
                    ORDER BY timestamp DESC
                    LIMIT 1
                )
                SELECT 
                    lrc.room_name,
                    lrc.room_power_on,
                    lrc.change_timestamp as current_since,
                    ROUND(EXTRACT('epoch' FROM (CURRENT_TIMESTAMP - lrc.change_timestamp::timestamp)) / 60, 1) as uptime_minutes
                FROM last_room_change lrc;"
            ;;
        *)
            echo -e "${RED}Invalid power type: $power_type${NC}" >&2
            return 1
            ;;
    esac
    
    execute_sql_clean "$sql" "get current uptime"
}

# Get next outage ID
get_next_outage_id() {
    check_database || return 1
    
    local sql="SELECT COALESCE(MAX(house_outage_id), 0) + 1 FROM power_status;"
    execute_sql "$sql" "get next outage ID"
}

# Get database statistics
get_database_stats() {
    check_database || return 1
    
    local sql="SELECT 
                   'switches' as table_name, COUNT(*) as record_count FROM switches
               UNION ALL
               SELECT 'rooms' as table_name, COUNT(*) as record_count FROM rooms
               UNION ALL
               SELECT 'power_status' as table_name, COUNT(*) as record_count FROM power_status
               UNION ALL
               SELECT 'room_power_status' as table_name, COUNT(*) as record_count FROM room_power_status
               UNION ALL
               SELECT 'switch_status' as table_name, COUNT(*) as record_count FROM switch_status
               ORDER BY table_name;"
    execute_sql "$sql" "get database statistics"
}

# Cleanup old records (data retention)
cleanup_old_records() {
    local days_to_keep="${1:-90}"
    
    check_database || return 1
    
    echo -e "${BLUE}Cleaning up records older than $days_to_keep days${NC}"
    
    # Clean switch_status (detailed logs)
    local sql="DELETE FROM switch_status WHERE timestamp < datetime('now', '-$days_to_keep days');"
    execute_sql "$sql" "cleanup old switch status records"
    
    # Note: Keep power_status and room_power_status for longer term analysis
    # These tables are smaller and contain important historical data
    
    echo -e "${GREEN}Database cleanup completed${NC}"
}

# Export data for migration (CSV format)
export_data() {
    local output_dir="$1"
    local table_name="${2:-all}"
    
    check_database || return 1
    
    mkdir -p "$output_dir"
    
    local tables=("switches" "rooms" "power_status" "room_power_status" "switch_status")
    
    if [[ "$table_name" != "all" ]]; then
        tables=("$table_name")
    fi
    
    for table in "${tables[@]}"; do
        echo -e "${BLUE}Exporting table: $table${NC}"
        local output_file="$output_dir/${table}.csv"
        local sql="COPY (SELECT * FROM $table) TO '$output_file' WITH (FORMAT CSV, HEADER);"
        execute_sql "$sql" "export table: $table"
    done
    
    echo -e "${GREEN}Data export completed to: $output_dir${NC}"
}