#!/bin/bash

# power-logic.sh - Backup-aware power state calculations and outage detection
# Handles the core logic for determining house and room power states

set -euo pipefail

# Power state constants
readonly POWER_STATE_ONLINE="ONLINE"
readonly POWER_STATE_BACKUP="BACKUP"
readonly POWER_STATE_CRITICAL="CRITICAL"
readonly POWER_STATE_OFFLINE="OFFLINE"

# Power threshold (percentage of switches that must be online)
readonly MAIN_POWER_THRESHOLD=50  # 50% of main power switches must be online
readonly ROOM_POWER_THRESHOLD=50  # 50% of room switches must be online

# Colors for output (fallback if not defined)
RED=${RED:-'\033[0;31m'}
GREEN=${GREEN:-'\033[0;32m'}
YELLOW=${YELLOW:-'\033[1;33m'}
BLUE=${BLUE:-'\033[0;34m'}
NC=${NC:-'\033[0m'}

# Calculate main power status based on non-backup switches
calculate_main_power_status() {
    local switches_data="$1"  # JSON array of switch status objects
    
    if [[ -z "$switches_data" ]]; then
        echo -e "${RED}Error: Switches data is required${NC}" >&2
        return 1
    fi
    
    local main_switches_online=0
    local main_switches_total=0
    
    # Count main power switches (backup_connected = false)
    while IFS= read -r switch_json; do
        if [[ -z "$switch_json" || "$switch_json" == "null" ]]; then
            continue
        fi
        
        local backup_connected is_authentic
        backup_connected=$(echo "$switch_json" | jq -r '.backup_connected // false')
        is_authentic=$(echo "$switch_json" | jq -r '.is_authentic // false')
        
        # Only count non-backup switches for main power calculation
        if [[ "$backup_connected" == "false" ]]; then
            ((main_switches_total++))
            if [[ "$is_authentic" == "true" ]]; then
                ((main_switches_online++))
            fi
        fi
        
    done < <(echo "$switches_data" | jq -c '.[]')
    
    # Calculate main power status
    local main_power_on=false
    local main_power_percentage=0
    
    if [[ $main_switches_total -gt 0 ]]; then
        main_power_percentage=$(( (main_switches_online * 100) / main_switches_total ))
        if [[ $main_power_percentage -ge $MAIN_POWER_THRESHOLD ]]; then
            main_power_on=true
        fi
    fi
    
    # Output results
    echo "main_switches_online:$main_switches_online"
    echo "main_switches_total:$main_switches_total"
    echo "main_power_percentage:$main_power_percentage"
    echo "main_power_on:$main_power_on"
    
    if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
        echo -e "${BLUE}[DEBUG] Main power: $main_switches_online/$main_switches_total (${main_power_percentage}%) = $main_power_on${NC}" >&2
    fi
}

# Calculate backup power status based on backup-connected switches
calculate_backup_power_status() {
    local switches_data="$1"  # JSON array of switch status objects
    
    if [[ -z "$switches_data" ]]; then
        echo -e "${RED}Error: Switches data is required${NC}" >&2
        return 1
    fi
    
    local backup_switches_online=0
    local backup_switches_total=0
    
    # Count backup switches (backup_connected = true)
    while IFS= read -r switch_json; do
        if [[ -z "$switch_json" || "$switch_json" == "null" ]]; then
            continue
        fi
        
        local backup_connected is_authentic
        backup_connected=$(echo "$switch_json" | jq -r '.backup_connected // false')
        is_authentic=$(echo "$switch_json" | jq -r '.is_authentic // false')
        
        # Only count backup-connected switches
        if [[ "$backup_connected" == "true" ]]; then
            ((backup_switches_total++))
            if [[ "$is_authentic" == "true" ]]; then
                ((backup_switches_online++))
            fi
        fi
        
    done < <(echo "$switches_data" | jq -c '.[]')
    
    # Calculate backup power status (ALL backup switches must be online)
    local backup_power_on=false
    local backup_power_percentage=0
    
    if [[ $backup_switches_total -gt 0 ]]; then
        backup_power_percentage=$(( (backup_switches_online * 100) / backup_switches_total ))
        if [[ $backup_switches_online -eq $backup_switches_total ]]; then
            backup_power_on=true
        fi
    else
        # If no backup switches configured, consider backup "unavailable" but not failed
        backup_power_on=true  # Don't trigger CRITICAL state due to no backup config
    fi
    
    # Output results
    echo "backup_switches_online:$backup_switches_online"
    echo "backup_switches_total:$backup_switches_total"
    echo "backup_power_percentage:$backup_power_percentage"
    echo "backup_power_on:$backup_power_on"
    
    if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
        echo -e "${BLUE}[DEBUG] Backup power: $backup_switches_online/$backup_switches_total (${backup_power_percentage}%) = $backup_power_on${NC}" >&2
    fi
}

# Determine overall system status based on main and backup power
determine_system_status() {
    local main_power_on="$1"
    local backup_power_on="$2"
    local backup_switches_total="$3"
    
    if [[ -z "$main_power_on" || -z "$backup_power_on" || -z "$backup_switches_total" ]]; then
        echo -e "${RED}Error: All power status parameters are required${NC}" >&2
        return 1
    fi
    
    local system_status
    
    if [[ "$main_power_on" == "true" ]]; then
        system_status="$POWER_STATE_ONLINE"
    elif [[ "$main_power_on" == "false" && "$backup_power_on" == "true" ]]; then
        system_status="$POWER_STATE_BACKUP"
    elif [[ "$backup_power_on" == "false" && $backup_switches_total -gt 0 ]]; then
        system_status="$POWER_STATE_CRITICAL"  # Backup failed
    else
        system_status="$POWER_STATE_OFFLINE"   # No power anywhere
    fi
    
    echo "system_status:$system_status"
    
    if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
        echo -e "${BLUE}[DEBUG] System status: main=$main_power_on, backup=$backup_power_on, total_backup=$backup_switches_total => $system_status${NC}" >&2
    fi
}

# Calculate room power status
calculate_room_power_status() {
    local switches_data="$1"  # JSON array of switch status objects
    local target_room="${2:-}"  # Optional: calculate for specific room only
    
    if [[ -z "$switches_data" ]]; then
        echo -e "${RED}Error: Switches data is required${NC}" >&2
        return 1
    fi
    
    # Group switches by room
    declare -A room_switches_online
    declare -A room_switches_total
    
    while IFS= read -r switch_json; do
        if [[ -z "$switch_json" || "$switch_json" == "null" ]]; then
            continue
        fi
        
        local room_name is_authentic
        room_name=$(echo "$switch_json" | jq -r '.room_name // .location // empty')
        is_authentic=$(echo "$switch_json" | jq -r '.is_authentic // false')
        
        if [[ -z "$room_name" ]]; then
            continue
        fi
        
        # Skip if target room specified and this isn't it
        if [[ -n "$target_room" && "$room_name" != "$target_room" ]]; then
            continue
        fi
        
        # Initialize room counters if not exists
        if [[ -z "${room_switches_total[$room_name]:-}" ]]; then
            room_switches_total[$room_name]=0
            room_switches_online[$room_name]=0
        fi
        
        ((room_switches_total[$room_name]++))
        if [[ "$is_authentic" == "true" ]]; then
            ((room_switches_online[$room_name]++))
        fi
        
    done < <(echo "$switches_data" | jq -c '.[]')
    
    # Calculate power status for each room
    for room_name in "${!room_switches_total[@]}"; do
        local switches_online=${room_switches_online[$room_name]}
        local switches_total=${room_switches_total[$room_name]}
        local room_power_on=false
        local room_power_percentage=0
        
        if [[ $switches_total -gt 0 ]]; then
            room_power_percentage=$(( (switches_online * 100) / switches_total ))
            if [[ $room_power_percentage -ge $ROOM_POWER_THRESHOLD ]]; then
                room_power_on=true
            fi
        fi
        
        # Output room status
        echo "---"  # Separator for each room
        echo "room_name:$room_name"
        echo "switches_online:$switches_online"
        echo "switches_total:$switches_total"
        echo "room_power_percentage:$room_power_percentage"
        echo "room_power_on:$room_power_on"
        
        if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
            echo -e "${BLUE}[DEBUG] Room $room_name: $switches_online/$switches_total (${room_power_percentage}%) = $room_power_on${NC}" >&2
        fi
    done
}

# Detect outage events and assign outage IDs
detect_outage_events() {
    local current_system_status="$1"
    local previous_system_status="${2:-}"
    local current_outage_id="${3:-}"
    
    if [[ -z "$current_system_status" ]]; then
        echo -e "${RED}Error: Current system status is required${NC}" >&2
        return 1
    fi
    
    local outage_id=""
    local is_outage_start=false
    local is_outage_end=false
    
    # Determine if this is an outage state
    local is_current_outage=false
    if [[ "$current_system_status" == "$POWER_STATE_BACKUP" || 
          "$current_system_status" == "$POWER_STATE_CRITICAL" || 
          "$current_system_status" == "$POWER_STATE_OFFLINE" ]]; then
        is_current_outage=true
    fi
    
    local is_previous_outage=false
    if [[ -n "$previous_system_status" ]]; then
        if [[ "$previous_system_status" == "$POWER_STATE_BACKUP" || 
              "$previous_system_status" == "$POWER_STATE_CRITICAL" || 
              "$previous_system_status" == "$POWER_STATE_OFFLINE" ]]; then
            is_previous_outage=true
        fi
    fi
    
    # Detect outage transitions
    if [[ "$is_current_outage" == true && "$is_previous_outage" == false ]]; then
        # Outage started
        is_outage_start=true
        # Generate new outage ID (will be handled by caller with database query)
        outage_id="NEW"
    elif [[ "$is_current_outage" == true && "$is_previous_outage" == true ]]; then
        # Outage continues
        outage_id="$current_outage_id"
    elif [[ "$is_current_outage" == false && "$is_previous_outage" == true ]]; then
        # Outage ended
        is_outage_end=true
        outage_id=""  # Clear outage ID
    else
        # Normal operation continues
        outage_id=""
    fi
    
    # Output outage detection results
    echo "is_outage_start:$is_outage_start"
    echo "is_outage_end:$is_outage_end"
    echo "outage_id:$outage_id"
    echo "is_current_outage:$is_current_outage"
    
    if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
        echo -e "${BLUE}[DEBUG] Outage detection: $previous_system_status -> $current_system_status (start=$is_outage_start, end=$is_outage_end, id=$outage_id)${NC}" >&2
    fi
}

# Calculate uptime from power status history
calculate_uptime() {
    local power_type="$1"  # "house" or "room"
    local current_status="$2"  # Current power status
    local last_change_timestamp="$3"  # When status last changed
    local target_room="${4:-}"  # Required if power_type is "room"
    
    if [[ -z "$power_type" || -z "$current_status" || -z "$last_change_timestamp" ]]; then
        echo -e "${RED}Error: Power type, current status, and last change timestamp are required${NC}" >&2
        return 1
    fi
    
    if [[ "$power_type" == "room" && -z "$target_room" ]]; then
        echo -e "${RED}Error: Room name is required for room uptime calculation${NC}" >&2
        return 1
    fi
    
    # Parse timestamp and calculate uptime
    local current_timestamp
    current_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Calculate uptime in seconds using date command
    local last_change_epoch current_epoch uptime_seconds
    if command -v date >/dev/null 2>&1; then
        # Try different date command variations for compatibility
        if last_change_epoch=$(date -d "$last_change_timestamp" +%s 2>/dev/null); then
            current_epoch=$(date +%s)
            uptime_seconds=$((current_epoch - last_change_epoch))
        elif last_change_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_change_timestamp" +%s 2>/dev/null); then
            # macOS date command
            current_epoch=$(date +%s)
            uptime_seconds=$((current_epoch - last_change_epoch))
        else
            echo -e "${YELLOW}Warning: Could not parse timestamp for uptime calculation${NC}" >&2
            uptime_seconds=0
        fi
    else
        uptime_seconds=0
    fi
    
    # Convert uptime to human-readable format
    local uptime_minutes uptime_hours uptime_days
    uptime_minutes=$((uptime_seconds / 60))
    uptime_hours=$((uptime_minutes / 60))
    uptime_days=$((uptime_hours / 24))
    
    local uptime_display=""
    if [[ $uptime_days -gt 0 ]]; then
        uptime_display="${uptime_days}d "
    fi
    if [[ $uptime_hours -gt 0 ]]; then
        uptime_display="${uptime_display}$((uptime_hours % 24))h "
    fi
    uptime_display="${uptime_display}$((uptime_minutes % 60))m"
    
    # Determine if current status represents "uptime"
    local is_up=false
    case "$power_type" in
        "house")
            if [[ "$current_status" == "$POWER_STATE_ONLINE" || "$current_status" == "$POWER_STATE_BACKUP" ]]; then
                is_up=true
            fi
            ;;
        "room")
            if [[ "$current_status" == "true" ]]; then
                is_up=true
            fi
            ;;
    esac
    
    # Output uptime information
    echo "power_type:$power_type"
    if [[ -n "$target_room" ]]; then
        echo "room_name:$target_room"
    fi
    echo "current_status:$current_status"
    echo "last_change_timestamp:$last_change_timestamp"
    echo "uptime_seconds:$uptime_seconds"
    echo "uptime_minutes:$uptime_minutes"
    echo "uptime_hours:$uptime_hours"
    echo "uptime_days:$uptime_days"
    echo "uptime_display:$uptime_display"
    echo "is_up:$is_up"
    
    if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
        echo -e "${BLUE}[DEBUG] Uptime: $power_type $current_status since $last_change_timestamp = $uptime_display${NC}" >&2
    fi
}

# Generate power status summary
generate_power_summary() {
    local switches_data="$1"
    local timestamp="${2:-$(date '+%Y-%m-%d %H:%M:%S')}"
    
    if [[ -z "$switches_data" ]]; then
        echo -e "${RED}Error: Switches data is required${NC}" >&2
        return 1
    fi
    
    echo "timestamp:$timestamp"
    echo "---"
    
    # Calculate main power status
    local main_power_result
    main_power_result=$(calculate_main_power_status "$switches_data")
    echo "$main_power_result"
    echo "---"
    
    # Calculate backup power status
    local backup_power_result
    backup_power_result=$(calculate_backup_power_status "$switches_data")
    echo "$backup_power_result"
    echo "---"
    
    # Extract values for system status calculation
    local main_power_on backup_power_on backup_switches_total
    main_power_on=$(echo "$main_power_result" | grep "main_power_on:" | cut -d: -f2)
    backup_power_on=$(echo "$backup_power_result" | grep "backup_power_on:" | cut -d: -f2)
    backup_switches_total=$(echo "$backup_power_result" | grep "backup_switches_total:" | cut -d: -f2)
    
    # Determine system status
    local system_status_result
    system_status_result=$(determine_system_status "$main_power_on" "$backup_power_on" "$backup_switches_total")
    echo "$system_status_result"
    echo "---"
    
    # Calculate room power status
    echo "room_power_status:"
    calculate_room_power_status "$switches_data"
}

# Validate power logic parameters
validate_power_thresholds() {
    local main_threshold="${1:-$MAIN_POWER_THRESHOLD}"
    local room_threshold="${2:-$ROOM_POWER_THRESHOLD}"
    
    if [[ ! "$main_threshold" =~ ^[0-9]+$ ]] || [[ $main_threshold -lt 0 || $main_threshold -gt 100 ]]; then
        echo -e "${RED}Error: Main power threshold must be 0-100${NC}" >&2
        return 1
    fi
    
    if [[ ! "$room_threshold" =~ ^[0-9]+$ ]] || [[ $room_threshold -lt 0 || $room_threshold -gt 100 ]]; then
        echo -e "${RED}Error: Room power threshold must be 0-100${NC}" >&2
        return 1
    fi
    
    echo "main_power_threshold:$main_threshold"
    echo "room_power_threshold:$room_threshold"
    
    if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
        echo -e "${GREEN}[DEBUG] Power thresholds validated: main=$main_threshold%, room=$room_threshold%${NC}" >&2
    fi
}

# Test power logic with sample data
test_power_logic() {
    echo -e "${BLUE}Testing power logic with sample data...${NC}"
    
    # Sample switch data for testing
    local test_switches='[
        {
            "label": "main-switch-1",
            "room_name": "living-room",
            "backup_connected": false,
            "is_authentic": true
        },
        {
            "label": "main-switch-2", 
            "room_name": "bedroom",
            "backup_connected": false,
            "is_authentic": false
        },
        {
            "label": "backup-switch-1",
            "room_name": "server-room",
            "backup_connected": true,
            "is_authentic": true
        }
    ]'
    
    echo -e "${YELLOW}Test scenario: 1/2 main switches online, 1/1 backup switches online${NC}"
    generate_power_summary "$test_switches"
    
    echo -e "\n${GREEN}Power logic test completed${NC}"
}

# Power state transition helpers

# Check if transition is valid
is_valid_power_transition() {
    local from_state="$1"
    local to_state="$2"
    
    # All transitions are technically valid, but some may indicate issues
    case "$from_state->$to_state" in
        "$POWER_STATE_ONLINE->$POWER_STATE_BACKUP")
            echo "valid:true,type:main_power_lost"
            ;;
        "$POWER_STATE_BACKUP->$POWER_STATE_ONLINE")
            echo "valid:true,type:main_power_restored"
            ;;
        "$POWER_STATE_BACKUP->$POWER_STATE_CRITICAL")
            echo "valid:true,type:backup_power_lost"
            ;;
        "$POWER_STATE_CRITICAL->$POWER_STATE_BACKUP")
            echo "valid:true,type:backup_power_restored"
            ;;
        "$POWER_STATE_CRITICAL->$POWER_STATE_ONLINE")
            echo "valid:true,type:full_power_restored"
            ;;
        "$POWER_STATE_ONLINE->$POWER_STATE_CRITICAL")
            echo "valid:true,type:catastrophic_failure"
            ;;
        "$POWER_STATE_ONLINE->$POWER_STATE_OFFLINE")
            echo "valid:true,type:total_power_loss"
            ;;
        "$POWER_STATE_OFFLINE->$POWER_STATE_ONLINE")
            echo "valid:true,type:power_restored"
            ;;
        *)
            if [[ "$from_state" == "$to_state" ]]; then
                echo "valid:true,type:no_change"
            else
                echo "valid:true,type:other_transition"
            fi
            ;;
    esac
}

# Get power state color for UI
get_power_state_color() {
    local power_state="$1"
    
    case "$power_state" in
        "$POWER_STATE_ONLINE")
            echo "green"
            ;;
        "$POWER_STATE_BACKUP")
            echo "yellow"
            ;;
        "$POWER_STATE_CRITICAL")
            echo "red"
            ;;
        "$POWER_STATE_OFFLINE")
            echo "red"
            ;;
        *)
            echo "white"
            ;;
    esac
}

# Get power state description
get_power_state_description() {
    local power_state="$1"
    
    case "$power_state" in
        "$POWER_STATE_ONLINE")
            echo "Main power available, all systems normal"
            ;;
        "$POWER_STATE_BACKUP")
            echo "Running on backup power, main power lost"
            ;;
        "$POWER_STATE_CRITICAL")
            echo "Backup power failed, system at risk"
            ;;
        "$POWER_STATE_OFFLINE")
            echo "No power detected anywhere"
            ;;
        *)
            echo "Unknown power state"
            ;;
    esac
}