#!/bin/bash

# config.sh - Configuration loading and validation for power monitoring
# Handles switches.json parsing, validation, and auto-discovery

set -euo pipefail

# Default configuration paths
DEFAULT_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)"
CONFIG_DIR="${POWER_MONITOR_CONFIG_DIR:-$DEFAULT_CONFIG_DIR}"
SWITCHES_CONFIG_FILE="$CONFIG_DIR/switches.json"

# Colors for output (fallback if not defined)
RED=${RED:-'\033[0;31m'}
GREEN=${GREEN:-'\033[0;32m'}
YELLOW=${YELLOW:-'\033[1;33m'}
BLUE=${BLUE:-'\033[0;34m'}
NC=${NC:-'\033[0m'}

# Check configuration dependencies
check_config_dependencies() {
    local missing_deps=()
    
    command -v jq >/dev/null || missing_deps+=("jq")
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo -e "${RED}Missing configuration dependencies: ${missing_deps[*]}${NC}" >&2
        echo "Please install jq: https://stedolan.github.io/jq/" >&2
        return 1
    fi
    
    return 0
}

# Validate switches configuration file
validate_switches_config() {
    local config_file="${1:-$SWITCHES_CONFIG_FILE}"
    
    check_config_dependencies || return 1
    
    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}Error: Switches configuration file not found: $config_file${NC}" >&2
        echo "Expected location: $SWITCHES_CONFIG_FILE" >&2
        return 1
    fi
    
    # Check if file is valid JSON
    if ! jq empty "$config_file" 2>/dev/null; then
        echo -e "${RED}Error: Invalid JSON in configuration file: $config_file${NC}" >&2
        return 1
    fi
    
    # Check if it's an array
    if [[ "$(jq 'type' "$config_file")" != '"array"' ]]; then
        echo -e "${RED}Error: Configuration file must contain a JSON array${NC}" >&2
        return 1
    fi
    
    # Validate each switch entry
    local switch_count
    switch_count=$(jq 'length' "$config_file")
    
    if [[ $switch_count -eq 0 ]]; then
        echo -e "${YELLOW}Warning: No switches configured in $config_file${NC}" >&2
        return 0
    fi
    
    local validation_errors=0
    
    for ((i=0; i<switch_count; i++)); do
        local switch_json
        switch_json=$(jq ".[$i]" "$config_file")
        
        # Validate required fields
        local label ip_address location mac_address
        label=$(echo "$switch_json" | jq -r '.label // empty')
        ip_address=$(echo "$switch_json" | jq -r '."ip-address" // ."ip_address" // empty')
        location=$(echo "$switch_json" | jq -r '.location // .room // empty')
        mac_address=$(echo "$switch_json" | jq -r '."mac-address" // ."mac_address" // empty')
        
        if [[ -z "$label" ]]; then
            echo -e "${RED}Error: Switch $i missing 'label' field${NC}" >&2
            ((validation_errors++))
        fi
        
        if [[ -z "$ip_address" ]]; then
            echo -e "${RED}Error: Switch '$label' missing 'ip-address' field${NC}" >&2
            ((validation_errors++))
        elif ! [[ "$ip_address" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo -e "${RED}Error: Switch '$label' has invalid IP address: $ip_address${NC}" >&2
            ((validation_errors++))
        fi
        
        if [[ -z "$location" ]]; then
            echo -e "${RED}Error: Switch '$label' missing 'location' field${NC}" >&2
            ((validation_errors++))
        fi
        
        if [[ -z "$mac_address" ]]; then
            echo -e "${RED}Error: Switch '$label' missing 'mac-address' field${NC}" >&2
            ((validation_errors++))
        elif ! [[ "$mac_address" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
            echo -e "${RED}Error: Switch '$label' has invalid MAC address: $mac_address${NC}" >&2
            ((validation_errors++))
        fi
        
        # Check for duplicate labels
        local duplicate_count
        duplicate_count=$(jq --arg label "$label" '[.[] | select(.label == $label)] | length' "$config_file")
        if [[ $duplicate_count -gt 1 ]]; then
            echo -e "${RED}Error: Duplicate switch label: $label${NC}" >&2
            ((validation_errors++))
        fi
        
        # Check for duplicate IP addresses
        local duplicate_ip_count
        duplicate_ip_count=$(jq --arg ip "$ip_address" '[.[] | select(."ip-address" == $ip or ."ip_address" == $ip)] | length' "$config_file")
        if [[ $duplicate_ip_count -gt 1 ]]; then
            echo -e "${RED}Error: Duplicate IP address: $ip_address (switch: $label)${NC}" >&2
            ((validation_errors++))
        fi
        
        # Validate backup-connected field if present
        local backup_connected
        backup_connected=$(echo "$switch_json" | jq -r '."backup-connected" // ."backup_connected" // empty')
        if [[ -n "$backup_connected" && "$backup_connected" != "true" && "$backup_connected" != "false" ]]; then
            echo -e "${RED}Error: Switch '$label' has invalid 'backup-connected' value: $backup_connected (must be true or false)${NC}" >&2
            ((validation_errors++))
        fi
        
        if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
            echo -e "${BLUE}[DEBUG] Validated switch: $label ($ip_address) in $location${NC}" >&2
        fi
    done
    
    if [[ $validation_errors -gt 0 ]]; then
        echo -e "${RED}Configuration validation failed with $validation_errors errors${NC}" >&2
        return 1
    fi
    
    echo -e "${GREEN}Configuration validation successful: $switch_count switches${NC}" >&2
    return 0
}

# Load switches configuration
load_switches_config() {
    local config_file="${1:-$SWITCHES_CONFIG_FILE}"
    
    validate_switches_config "$config_file" || return 1
    
    if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
        echo -e "${BLUE}[DEBUG] Loading switches from: $config_file${NC}" >&2
    fi
    
    # Output the switches array
    jq '.' "$config_file"
}

# Get switches for a specific room
get_switches_by_room() {
    local room_name="$1"
    local config_file="${2:-$SWITCHES_CONFIG_FILE}"
    
    if [[ -z "$room_name" ]]; then
        echo -e "${RED}Error: Room name is required${NC}" >&2
        return 1
    fi
    
    validate_switches_config "$config_file" || return 1
    
    jq --arg room "$room_name" '[.[] | select(.location == $room or .room == $room)]' "$config_file"
}

# Get all room names
get_room_names() {
    local config_file="${1:-$SWITCHES_CONFIG_FILE}"
    
    validate_switches_config "$config_file" || return 1
    
    jq -r '[.[] | .location // .room] | unique | .[]' "$config_file"
}

# Get backup-connected switches
get_backup_switches() {
    local config_file="${1:-$SWITCHES_CONFIG_FILE}"
    
    validate_switches_config "$config_file" || return 1
    
    jq '[.[] | select(."backup-connected" == true or ."backup_connected" == true)]' "$config_file"
}

# Get main power switches (non-backup)
get_main_power_switches() {
    local config_file="${1:-$SWITCHES_CONFIG_FILE}"
    
    validate_switches_config "$config_file" || return 1
    
    jq '[.[] | select(."backup-connected" != true and ."backup_connected" != true)]' "$config_file"
}

# Get switch by label
get_switch_by_label() {
    local label="$1"
    local config_file="${2:-$SWITCHES_CONFIG_FILE}"
    
    if [[ -z "$label" ]]; then
        echo -e "${RED}Error: Switch label is required${NC}" >&2
        return 1
    fi
    
    validate_switches_config "$config_file" || return 1
    
    local switch_data
    switch_data=$(jq --arg label "$label" '.[] | select(.label == $label)' "$config_file")
    
    if [[ -z "$switch_data" || "$switch_data" == "null" ]]; then
        echo -e "${RED}Error: Switch not found: $label${NC}" >&2
        return 1
    fi
    
    echo "$switch_data"
}

# Normalize switch configuration (standardize field names)
normalize_switches_config() {
    local config_file="${1:-$SWITCHES_CONFIG_FILE}"
    local output_file="${2:-}"
    
    validate_switches_config "$config_file" || return 1
    
    # Normalize field names and add missing fields
    local normalized_config
    normalized_config=$(jq '[.[] | {
        label: .label,
        ip_address: (."ip-address" // ."ip_address"),
        room_name: (.location // .room),
        mac_address: (."mac-address" // ."mac_address"),
        backup_connected: (."backup-connected" // ."backup_connected" // false)
    }]' "$config_file")
    
    if [[ -n "$output_file" ]]; then
        echo "$normalized_config" > "$output_file"
        echo -e "${GREEN}Normalized configuration written to: $output_file${NC}" >&2
    else
        echo "$normalized_config"
    fi
}

# Create sample configuration file
create_sample_config() {
    local output_file="${1:-$CONFIG_DIR/switches.json.example}"
    
    # Create config directory if it doesn't exist
    mkdir -p "$(dirname "$output_file")"
    
    cat > "$output_file" << 'EOF'
[
  {
    "label": "living-room-lamp",
    "ip-address": "192.168.1.100",
    "location": "living-room",
    "mac-address": "aa:bb:cc:dd:ee:01",
    "backup-connected": false
  },
  {
    "label": "bedroom-clock",
    "ip-address": "192.168.1.101",
    "location": "bedroom",
    "mac-address": "aa:bb:cc:dd:ee:02",
    "backup-connected": false
  },
  {
    "label": "server-switch",
    "ip-address": "192.168.1.102",
    "location": "server-room",
    "mac-address": "aa:bb:cc:dd:ee:03",
    "backup-connected": true
  },
  {
    "label": "backup-router",
    "ip-address": "192.168.1.103",
    "location": "server-room",
    "mac-address": "aa:bb:cc:dd:ee:04",
    "backup-connected": true
  }
]
EOF
    
    echo -e "${GREEN}Sample configuration created: $output_file${NC}"
    echo "Edit this file with your actual switch details, then copy to $SWITCHES_CONFIG_FILE"
}

# Add switch to configuration
add_switch_to_config() {
    local label="$1"
    local ip_address="$2"
    local room_name="$3"
    local mac_address="$4"
    local backup_connected="${5:-false}"
    local config_file="${6:-$SWITCHES_CONFIG_FILE}"
    
    if [[ -z "$label" || -z "$ip_address" || -z "$room_name" || -z "$mac_address" ]]; then
        echo -e "${RED}Error: All switch parameters are required (label, ip_address, room_name, mac_address)${NC}" >&2
        return 1
    fi
    
    # Validate inputs
    if ! [[ "$ip_address" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo -e "${RED}Error: Invalid IP address format: $ip_address${NC}" >&2
        return 1
    fi
    
    if ! [[ "$mac_address" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
        echo -e "${RED}Error: Invalid MAC address format: $mac_address${NC}" >&2
        return 1
    fi
    
    if [[ "$backup_connected" != "true" && "$backup_connected" != "false" ]]; then
        echo -e "${RED}Error: backup_connected must be 'true' or 'false'${NC}" >&2
        return 1
    fi
    
    # Create config file if it doesn't exist
    if [[ ! -f "$config_file" ]]; then
        echo '[]' > "$config_file"
    fi
    
    # Check if switch already exists
    if jq --arg label "$label" '.[] | select(.label == $label)' "$config_file" | grep -q .; then
        echo -e "${RED}Error: Switch with label '$label' already exists${NC}" >&2
        return 1
    fi
    
    # Add new switch
    local new_switch
    new_switch=$(jq -n --arg label "$label" \
                      --arg ip "$ip_address" \
                      --arg room "$room_name" \
                      --arg mac "$mac_address" \
                      --argjson backup "$backup_connected" \
                      '{
                          "label": $label,
                          "ip-address": $ip,
                          "location": $room,
                          "mac-address": $mac,
                          "backup-connected": $backup
                      }')
    
    # Update configuration file
    local updated_config
    updated_config=$(jq --argjson switch "$new_switch" '. + [$switch]' "$config_file")
    echo "$updated_config" > "$config_file"
    
    echo -e "${GREEN}Switch '$label' added to configuration${NC}"
    
    # Validate the updated configuration
    validate_switches_config "$config_file"
}

# Remove switch from configuration
remove_switch_from_config() {
    local label="$1"
    local config_file="${2:-$SWITCHES_CONFIG_FILE}"
    
    if [[ -z "$label" ]]; then
        echo -e "${RED}Error: Switch label is required${NC}" >&2
        return 1
    fi
    
    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}Error: Configuration file not found: $config_file${NC}" >&2
        return 1
    fi
    
    # Check if switch exists
    if ! jq --arg label "$label" '.[] | select(.label == $label)' "$config_file" | grep -q .; then
        echo -e "${RED}Error: Switch with label '$label' not found${NC}" >&2
        return 1
    fi
    
    # Remove switch
    local updated_config
    updated_config=$(jq --arg label "$label" '[.[] | select(.label != $label)]' "$config_file")
    echo "$updated_config" > "$config_file"
    
    echo -e "${GREEN}Switch '$label' removed from configuration${NC}"
    
    # Validate the updated configuration
    validate_switches_config "$config_file"
}

# Update switch in configuration
update_switch_in_config() {
    local label="$1"
    local field="$2"
    local value="$3"
    local config_file="${4:-$SWITCHES_CONFIG_FILE}"
    
    if [[ -z "$label" || -z "$field" || -z "$value" ]]; then
        echo -e "${RED}Error: Label, field, and value are required${NC}" >&2
        return 1
    fi
    
    # Validate field name
    case "$field" in
        "ip-address"|"ip_address"|"location"|"room"|"mac-address"|"mac_address"|"backup-connected"|"backup_connected")
            ;;
        *)
            echo -e "${RED}Error: Invalid field name: $field${NC}" >&2
            echo "Valid fields: ip-address, location, mac-address, backup-connected" >&2
            return 1
            ;;
    esac
    
    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}Error: Configuration file not found: $config_file${NC}" >&2
        return 1
    fi
    
    # Check if switch exists
    if ! jq --arg label "$label" '.[] | select(.label == $label)' "$config_file" | grep -q .; then
        echo -e "${RED}Error: Switch with label '$label' not found${NC}" >&2
        return 1
    fi
    
    # Validate value based on field
    case "$field" in
        "ip-address"|"ip_address")
            if ! [[ "$value" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo -e "${RED}Error: Invalid IP address format: $value${NC}" >&2
                return 1
            fi
            ;;
        "mac-address"|"mac_address")
            if ! [[ "$value" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
                echo -e "${RED}Error: Invalid MAC address format: $value${NC}" >&2
                return 1
            fi
            ;;
        "backup-connected"|"backup_connected")
            if [[ "$value" != "true" && "$value" != "false" ]]; then
                echo -e "${RED}Error: backup-connected must be 'true' or 'false'${NC}" >&2
                return 1
            fi
            ;;
    esac
    
    # Update switch
    local updated_config
    if [[ "$field" == "backup-connected" || "$field" == "backup_connected" ]]; then
        # Boolean field
        updated_config=$(jq --arg label "$label" --argjson value "$value" \
                            'map(if .label == $label then .["backup-connected"] = $value else . end)' \
                            "$config_file")
    else
        # String field
        updated_config=$(jq --arg label "$label" --arg field "$field" --arg value "$value" \
                            'map(if .label == $label then .[$field] = $value else . end)' \
                            "$config_file")
    fi
    
    echo "$updated_config" > "$config_file"
    
    echo -e "${GREEN}Switch '$label' field '$field' updated to '$value'${NC}"
    
    # Validate the updated configuration
    validate_switches_config "$config_file"
}

# Show configuration statistics
show_config_stats() {
    local config_file="${1:-$SWITCHES_CONFIG_FILE}"
    
    if ! validate_switches_config "$config_file" >/dev/null 2>&1; then
        echo -e "${RED}Cannot show stats: configuration validation failed${NC}" >&2
        return 1
    fi
    
    local total_switches backup_switches main_switches rooms
    total_switches=$(jq 'length' "$config_file")
    backup_switches=$(jq '[.[] | select(."backup-connected" == true or ."backup_connected" == true)] | length' "$config_file")
    main_switches=$((total_switches - backup_switches))
    rooms=$(jq -r '[.[] | .location // .room] | unique | length' "$config_file")
    
    echo -e "${BLUE}Configuration Statistics:${NC}"
    echo "Total switches: $total_switches"
    echo "Main power switches: $main_switches"
    echo "Backup power switches: $backup_switches"
    echo "Rooms: $rooms"
    echo ""
    
    echo -e "${BLUE}Switches by room:${NC}"
    while IFS= read -r room; do
        local room_count
        room_count=$(jq --arg room "$room" '[.[] | select(.location == $room or .room == $room)] | length' "$config_file")
        echo "  $room: $room_count switches"
    done < <(get_room_names "$config_file")
    
    echo ""
    echo -e "${BLUE}Backup switches:${NC}"
    jq -r '.[] | select(."backup-connected" == true or ."backup_connected" == true) | "  \(.label) (\(.location // .room))"' "$config_file"
}

# Export configuration for external use
export_config() {
    local format="${1:-json}"
    local config_file="${2:-$SWITCHES_CONFIG_FILE}"
    local output_file="${3:-}"
    
    if ! validate_switches_config "$config_file" >/dev/null 2>&1; then
        echo -e "${RED}Cannot export: configuration validation failed${NC}" >&2
        return 1
    fi
    
    local output
    case "$format" in
        "json")
            output=$(normalize_switches_config "$config_file")
            ;;
        "csv")
            output="label,ip_address,room_name,mac_address,backup_connected"$'\n'
            output+=$(jq -r '.[] | [.label, (."ip-address" // ."ip_address"), (.location // .room), (."mac-address" // ."mac_address"), (."backup-connected" // ."backup_connected" // false)] | @csv' "$config_file")
            ;;
        "tsv")
            output="label"$'\t'"ip_address"$'\t'"room_name"$'\t'"mac_address"$'\t'"backup_connected"
            output+=$'\n'$(jq -r '.[] | [.label, (."ip-address" // ."ip_address"), (.location // .room), (."mac-address" // ."mac_address"), (."backup-connected" // ."backup_connected" // false)] | @tsv' "$config_file")
            ;;
        *)
            echo -e "${RED}Error: Unsupported format: $format${NC}" >&2
            echo "Supported formats: json, csv, tsv" >&2
            return 1
            ;;
    esac
    
    if [[ -n "$output_file" ]]; then
        echo "$output" > "$output_file"
        echo -e "${GREEN}Configuration exported to: $output_file${NC}"
    else
        echo "$output"
    fi
}