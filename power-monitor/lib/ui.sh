#!/bin/bash

# ui.sh - Gum styling and color-coded status displays for power monitoring
# Provides beautiful terminal UI components with consistent styling

set -euo pipefail

# UI constants
readonly UI_WIDTH_HEADER=60
readonly UI_WIDTH_TABLE=80
readonly UI_PADDING="1 2"
readonly UI_MARGIN="1 2"

# Colors (used as fallback when gum not available)
RED=${RED:-'\033[0;31m'}
GREEN=${GREEN:-'\033[0;32m'}
YELLOW=${YELLOW:-'\033[1;33m'}
BLUE=${BLUE:-'\033[0;34m'}
PURPLE=${PURPLE:-'\033[0;35m'}
CYAN=${CYAN:-'\033[0;36m'}
WHITE=${WHITE:-'\033[1;37m'}
NC=${NC:-'\033[0m'}

# Check if gum is available and we're in interactive mode
check_gum_available() {
    if [[ "${POWER_MONITOR_NON_INTERACTIVE:-false}" == "true" ]]; then
        return 1  # Force fallback mode in non-interactive
    fi
    command -v gum >/dev/null 2>&1
}

# Fallback styling when gum is not available
style_fallback() {
    local text="$1"
    local color="${2:-white}"
    
    # In non-interactive mode, output plain text without colors
    if [[ "${POWER_MONITOR_NON_INTERACTIVE:-false}" == "true" ]]; then
        echo "$text"
        return
    fi
    
    case "$color" in
        "red") echo -e "${RED}$text${NC}" ;;
        "green") echo -e "${GREEN}$text${NC}" ;;
        "yellow") echo -e "${YELLOW}$text${NC}" ;;
        "blue") echo -e "${BLUE}$text${NC}" ;;
        "purple") echo -e "${PURPLE}$text${NC}" ;;
        "cyan") echo -e "${CYAN}$text${NC}" ;;
        *) echo -e "${WHITE}$text${NC}" ;;
    esac
}

# Main header styling
show_header() {
    local title="$1"
    local subtitle="${2:-}"
    
    if check_gum_available; then
        if [[ -n "$subtitle" ]]; then
            gum style \
                --foreground 212 --border-foreground 212 --border double \
                --align center --width $UI_WIDTH_HEADER --margin "$UI_MARGIN" --padding "2 4" \
                "$title" "$subtitle"
        else
            gum style \
                --foreground 212 --border-foreground 212 --border double \
                --align center --width $UI_WIDTH_HEADER --margin "$UI_MARGIN" --padding "2 4" \
                "$title"
        fi
    else
        echo
        style_fallback "═══════════════════════════════════════════════════════" "purple"
        style_fallback "                    $title" "purple"
        if [[ -n "$subtitle" ]]; then
            style_fallback "                 $subtitle" "purple"
        fi
        style_fallback "═══════════════════════════════════════════════════════" "purple"
        echo
    fi
}

# Section headers
show_section_header() {
    local title="$1"
    local color="${2:-blue}"
    
    if check_gum_available; then
        gum style --foreground "$color" --bold --margin "1 0" "$title"
    else
        echo
        style_fallback "$title" "$color"
        style_fallback "$(printf '%.0s─' $(seq 1 ${#title}))" "$color"
    fi
}

# Status formatting functions
format_status_online() {
    local text="${1:-ONLINE}"
    
    if check_gum_available; then
        gum style --background 2 --foreground 0 --padding "0 1" "$text"
    else
        style_fallback " $text " "green"
    fi
}

format_status_backup() {
    local text="${1:-BACKUP}"
    
    if check_gum_available; then
        gum style --background 3 --foreground 0 --padding "0 1" "$text"
    else
        style_fallback " $text " "yellow"
    fi
}

format_status_partial() {
    local text="${1:-PARTIAL}"
    
    if check_gum_available; then
        gum style --background 3 --foreground 0 --padding "0 1" "$text"
    else
        style_fallback " $text " "yellow"
    fi
}

format_status_critical() {
    local text="${1:-CRITICAL}"
    
    if check_gum_available; then
        gum style --background 1 --foreground 15 --padding "0 1" "$text"
    else
        style_fallback " $text " "red"
    fi
}

format_status_offline() {
    local text="${1:-OFFLINE}"
    
    if check_gum_available; then
        gum style --background 1 --foreground 15 --padding "0 1" "$text"
    else
        style_fallback " $text " "red"
    fi
}

# Format power status based on value
format_power_status() {
    local status="$1"
    local percentage="${2:-}"
    
    case "$status" in
        "ONLINE"|"true"|true)
            format_status_online "ONLINE"
            ;;
        "BACKUP")
            format_status_backup "BACKUP"
            ;;
        "PARTIAL")
            format_status_partial "PARTIAL"
            ;;
        "CRITICAL")
            format_status_critical "CRITICAL"
            ;;
        "OFFLINE"|"false"|false)
            format_status_offline "OFFLINE"
            ;;
        *)
            if [[ -n "$percentage" ]]; then
                if [[ $percentage -ge 75 ]]; then
                    format_status_online "ONLINE"
                elif [[ $percentage -ge 50 ]]; then
                    format_status_partial "PARTIAL"
                else
                    format_status_offline "OFFLINE"
                fi
            else
                format_status_offline "UNKNOWN"
            fi
            ;;
    esac
}

# System status display with description
show_system_status() {
    local system_status="$1"
    local uptime_display="${2:-}"
    local additional_info="${3:-}"
    
    echo
    show_section_header "System Status" "cyan"
    
    local status_text=""
    case "$system_status" in
        "ONLINE")
            status_text="Main power available, all systems normal"
            ;;
        "BACKUP")
            status_text="Running on backup power"
            if [[ -n "$uptime_display" ]]; then
                status_text="$status_text (Main power lost $uptime_display ago)"
            fi
            ;;
        "CRITICAL")
            status_text="⚠️  BACKUP POWER FAILED - System at risk"
            ;;
        "OFFLINE")
            status_text="⚠️  NO POWER DETECTED ANYWHERE"
            ;;
        *)
            status_text="Unknown system status: $system_status"
            ;;
    esac
    
    echo -n "Status: "
    format_power_status "$system_status"
    echo " - $status_text"
    
    if [[ -n "$additional_info" ]]; then
        echo "$additional_info"
    fi
    echo
}

# Table creation and display
create_room_status_table() {
    local room_data="$1"  # Tab-separated values: room_name \t switches_online/total \t status \t uptime \t backup
    
    if [[ -z "$room_data" ]]; then
        echo "No room data available"
        return 1
    fi
    
    if check_gum_available; then
        # Use gum table for beautiful display
        echo "$room_data" | gum table \
            --columns "Room,Switches,Status,Uptime,Backup" \
            --widths "15,10,8,12,8" \
            --height 10
    else
        # Fallback ASCII table
        echo
        printf "%-15s %-10s %-8s %-12s %-8s\n" "Room" "Switches" "Status" "Uptime" "Backup"
        printf "%-15s %-10s %-8s %-12s %-8s\n" "───────────────" "──────────" "────────" "────────────" "────────"
        
        while IFS=$'\t' read -r room switches status uptime backup; do
            [[ -z "$room" ]] && continue
            printf "%-15s %-10s " "$room" "$switches"
            
            # Format status with colors
            case "$status" in
                *"ONLINE"*) style_fallback "ONLINE  " "green" ;;
                *"PARTIAL"*) style_fallback "PARTIAL " "yellow" ;;
                *"BACKUP"*) style_fallback "BACKUP  " "yellow" ;;
                *"OFFLINE"*) style_fallback "OFFLINE " "red" ;;
                *) printf "%-8s" "$status" ;;
            esac
            
            printf " %-12s %-8s\n" "$uptime" "$backup"
        done <<< "$room_data"
        echo
    fi
}

# Switch status table
create_switch_status_table() {
    local switch_data="$1"  # Tab-separated values: label \t ip_address \t room \t status \t response_time \t backup
    
    if [[ -z "$switch_data" ]]; then
        echo "No switch data available"
        return 1
    fi
    
    if check_gum_available; then
        echo "$switch_data" | gum table \
            --columns "Switch,IP Address,Room,Status,Response,Backup" \
            --widths "12,15,12,8,10,8" \
            --height 15
    else
        echo
        printf "%-12s %-15s %-12s %-8s %-10s %-8s\n" "Switch" "IP Address" "Room" "Status" "Response" "Backup"
        printf "%-12s %-15s %-12s %-8s %-10s %-8s\n" "────────────" "───────────────" "────────────" "────────" "──────────" "────────"
        
        while IFS=$'\t' read -r label ip_address room status response backup; do
            [[ -z "$label" ]] && continue
            printf "%-12s %-15s %-12s " "$label" "$ip_address" "$room"
            
            case "$status" in
                *"ONLINE"*|*"TRUE"*) style_fallback "ONLINE  " "green" ;;
                *"OFFLINE"*|*"FALSE"*) style_fallback "OFFLINE " "red" ;;
                *) printf "%-8s" "$status" ;;
            esac
            
            printf " %-10s %-8s\n" "$response" "$backup"
        done <<< "$switch_data"
        echo
    fi
}

# History/outage table
create_outage_history_table() {
    local outage_data="$1"  # Tab-separated values: start_time \t end_time \t duration \t type \t affected_rooms
    
    if [[ -z "$outage_data" ]]; then
        echo "No outage history available"
        return 1
    fi
    
    if check_gum_available; then
        echo "$outage_data" | gum table \
            --columns "Start Time,End Time,Duration,Type,Affected" \
            --widths "16,16,10,12,15" \
            --height 10
    else
        echo
        printf "%-16s %-16s %-10s %-12s %-15s\n" "Start Time" "End Time" "Duration" "Type" "Affected"
        printf "%-16s %-16s %-10s %-12s %-15s\n" "────────────────" "────────────────" "──────────" "────────────" "───────────────"
        
        while IFS=$'\t' read -r start_time end_time duration type affected; do
            [[ -z "$start_time" ]] && continue
            
            # Color code by outage type
            case "$type" in
                *"CRITICAL"*) 
                    printf "%-16s %-16s %-10s " "$start_time" "$end_time" "$duration"
                    style_fallback "CRITICAL    " "red"
                    printf " %-15s\n" "$affected"
                    ;;
                *"BACKUP"*)
                    printf "%-16s %-16s %-10s " "$start_time" "$end_time" "$duration"
                    style_fallback "BACKUP      " "yellow"
                    printf " %-15s\n" "$affected"
                    ;;
                *)
                    printf "%-16s %-16s %-10s %-12s %-15s\n" "$start_time" "$end_time" "$duration" "$type" "$affected"
                    ;;
            esac
        done <<< "$outage_data"
        echo
    fi
}

# Progress spinner for network operations
show_progress_spinner() {
    local message="$1"
    local command="$2"
    
    if check_gum_available; then
        gum spin --spinner dot --title "$message" -- $command
    else
        echo "$message..."
        eval "$command"
    fi
}

# Interactive room selection
select_room_interactive() {
    local rooms_list="$1"
    local header="${2:-Select room:}"
    
    if [[ -z "$rooms_list" ]]; then
        echo -e "${RED}No rooms available for selection${NC}" >&2
        return 1
    fi
    
    if check_gum_available; then
        echo "$rooms_list" | gum choose --header "$header" --height 10
    else
        echo "$header"
        local i=1
        while IFS= read -r room; do
            echo "$i) $room"
            ((i++))
        done <<< "$rooms_list"
        
        echo -n "Enter selection (1-$((i-1))): "
        read -r selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ $selection -ge 1 && $selection -lt $i ]]; then
            echo "$rooms_list" | sed -n "${selection}p"
        else
            echo -e "${RED}Invalid selection${NC}" >&2
            return 1
        fi
    fi
}

# Confirmation prompts
confirm_action() {
    local message="$1"
    local default="${2:-false}"
    
    if check_gum_available; then
        gum confirm "$message"
    else
        local prompt="$message (y/N): "
        if [[ "$default" == "true" ]]; then
            prompt="$message (Y/n): "
        fi
        
        echo -n "$prompt"
        read -r response
        
        case "$response" in
            [Yy]|[Yy][Ee][Ss])
                return 0
                ;;
            [Nn]|[Nn][Oo])
                return 1
                ;;
            "")
                if [[ "$default" == "true" ]]; then
                    return 0
                else
                    return 1
                fi
                ;;
            *)
                return 1
                ;;
        esac
    fi
}

# Input prompts
prompt_input() {
    local prompt="$1"
    local placeholder="${2:-}"
    local password="${3:-false}"
    
    if check_gum_available; then
        if [[ "$password" == "true" ]]; then
            gum input --password --placeholder "$placeholder" --prompt "$prompt"
        else
            gum input --placeholder "$placeholder" --prompt "$prompt"
        fi
    else
        echo -n "$prompt"
        if [[ "$password" == "true" ]]; then
            read -s -r input
            echo
        else
            read -r input
        fi
        echo "$input"
    fi
}

# Multi-line text input
prompt_text() {
    local prompt="$1"
    local placeholder="${2:-Enter text...}"
    
    if check_gum_available; then
        gum write --placeholder "$placeholder" --prompt "$prompt"
    else
        echo "$prompt"
        echo "Enter text (Ctrl+D when done):"
        cat
    fi
}

# File picker
select_file() {
    local path="${1:-.}"
    local header="${2:-Select file:}"
    
    if check_gum_available; then
        gum file "$path" --directory="$path" --header "$header"
    else
        echo "$header"
        echo "Files in $path:"
        ls -la "$path"
        echo -n "Enter filename: "
        read -r filename
        echo "$path/$filename"
    fi
}

# Error and success messages
show_error() {
    local message="$1"
    
    if check_gum_available; then
        gum style --foreground 1 --bold "ERROR: $message" >&2
    else
        style_fallback "ERROR: $message" "red" >&2
    fi
}

show_success() {
    local message="$1"
    
    if check_gum_available; then
        gum style --foreground 2 --bold "SUCCESS: $message"
    else
        style_fallback "SUCCESS: $message" "green"
    fi
}

show_warning() {
    local message="$1"
    
    if check_gum_available; then
        gum style --foreground 3 --bold "WARNING: $message" >&2
    else
        style_fallback "WARNING: $message" "yellow" >&2
    fi
}

show_info() {
    local message="$1"
    
    if check_gum_available; then
        gum style --foreground 4 "INFO: $message"
    else
        style_fallback "INFO: $message" "blue"
    fi
}

# Pagination for long output
paginate_output() {
    local content="$1"
    local height="${2:-20}"
    
    if check_gum_available; then
        echo "$content" | gum pager --height "$height"
    else
        echo "$content" | less -R
    fi
}

# Format uptime display
format_uptime() {
    local uptime_seconds="$1"
    local current_status="${2:-up}"
    
    if [[ -z "$uptime_seconds" ]] || [[ "$uptime_seconds" -eq 0 ]]; then
        echo "--"
        return
    fi
    
    local days hours minutes
    days=$((uptime_seconds / 86400))
    hours=$(((uptime_seconds % 86400) / 3600))
    minutes=$(((uptime_seconds % 3600) / 60))
    
    local uptime_str=""
    if [[ $days -gt 0 ]]; then
        uptime_str="${days}d "
    fi
    if [[ $hours -gt 0 ]]; then
        uptime_str="${uptime_str}${hours}h "
    fi
    uptime_str="${uptime_str}${minutes}m"
    
    # Add status indicator
    if [[ "$current_status" == "up" ]]; then
        if check_gum_available; then
            gum style --foreground 2 "$uptime_str"
        else
            style_fallback "$uptime_str" "green"
        fi
    else
        if check_gum_available; then
            gum style --foreground 1 "down"
        else
            style_fallback "down" "red"
        fi
    fi
}

# Format percentage with color coding
format_percentage() {
    local percentage="$1"
    local threshold_good="${2:-75}"
    local threshold_ok="${3:-50}"
    
    if [[ $percentage -ge $threshold_good ]]; then
        if check_gum_available; then
            gum style --foreground 2 "${percentage}%"
        else
            style_fallback "${percentage}%" "green"
        fi
    elif [[ $percentage -ge $threshold_ok ]]; then
        if check_gum_available; then
            gum style --foreground 3 "${percentage}%"
        else
            style_fallback "${percentage}%" "yellow"
        fi
    else
        if check_gum_available; then
            gum style --foreground 1 "${percentage}%"
        else
            style_fallback "${percentage}%" "red"
        fi
    fi
}

# Loading animations
show_loading() {
    local message="${1:-Loading...}"
    local duration="${2:-3}"
    
    if check_gum_available; then
        gum spin --spinner line --title "$message" -- sleep "$duration"
    else
        echo -n "$message "
        for ((i=0; i<duration; i++)); do
            echo -n "."
            sleep 1
        done
        echo " done"
    fi
}

# Summary boxes
show_summary_box() {
    local title="$1"
    local content="$2"
    local color="${3:-blue}"
    
    if check_gum_available; then
        gum style \
            --foreground "$color" --border-foreground "$color" --border rounded \
            --padding "1 2" --margin "1" \
            --width 50 \
            "$title" "$content"
    else
        echo
        style_fallback "┌─ $title ─────────────────────────────────────────┐" "$color"
        while IFS= read -r line; do
            printf "│ %-47s │\n" "$line"
        done <<< "$content"
        style_fallback "└─────────────────────────────────────────────────┘" "$color"
        echo
    fi
}

# Help text formatting
format_help_text() {
    local help_content="$1"
    
    if check_gum_available; then
        echo "$help_content" | gum format
    else
        echo "$help_content"
    fi
}

# Test UI components
test_ui_components() {
    echo "Testing UI components..."
    echo
    
    # Test header
    show_header "Power Monitor Test" "UI Component Testing"
    
    # Test status formats
    show_section_header "Status Formats"
    echo -n "Online: "; format_status_online
    echo -n "Backup: "; format_status_backup  
    echo -n "Critical: "; format_status_critical
    echo -n "Offline: "; format_status_offline
    echo
    
    # Test table
    show_section_header "Sample Table"
    local sample_data="Living Room	3/3	ONLINE	2d 15h 23m	No
Bedroom	2/2	ONLINE	2d 15h 23m	No  
Kitchen	1/2	PARTIAL	--	No
Server Room	1/1	ONLINE	2d 15h 23m	Yes"
    
    create_room_status_table "$sample_data"
    
    # Test messages
    show_success "UI components test completed"
    show_warning "This is a test warning"
    show_error "This is a test error"
    show_info "This is test information"
    
    echo "UI test completed."
}