#!/bin/bash

# network.sh - Switch connectivity testing and MAC address validation
# Provides two-stage validation: ping connectivity + ARP MAC address verification

set -euo pipefail

# Default network settings
DEFAULT_PING_TIMEOUT=5
DEFAULT_PING_COUNT=1
DEFAULT_ARP_TIMEOUT=10

# Colors for output (fallback if not defined)
RED=${RED:-'\033[0;31m'}
GREEN=${GREEN:-'\033[0;32m'}
YELLOW=${YELLOW:-'\033[1;33m'}
BLUE=${BLUE:-'\033[0;34m'}
NC=${NC:-'\033[0m'}

# Check network dependencies
check_network_dependencies() {
    local missing_deps=()
    
    command -v ping >/dev/null || missing_deps+=("ping")
    
    # Check for ARP command (arp or ip neigh)
    if ! command -v arp >/dev/null 2>&1 && ! command -v ip >/dev/null 2>&1; then
        missing_deps+=("arp or ip")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo -e "${RED}Missing network dependencies: ${missing_deps[*]}${NC}" >&2
        return 1
    fi
    
    return 0
}

# Ping a single IP address
ping_switch() {
    local ip_address="$1"
    local timeout="${2:-$DEFAULT_PING_TIMEOUT}"
    local count="${3:-$DEFAULT_PING_COUNT}"
    
    if [[ -z "$ip_address" ]]; then
        echo -e "${RED}Error: IP address is required${NC}" >&2
        return 1
    fi
    
    # Validate IP address format (basic check)
    if ! [[ "$ip_address" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo -e "${RED}Error: Invalid IP address format: $ip_address${NC}" >&2
        return 1
    fi
    
    local start_time response_time
    start_time=$(date +%s%3N)  # milliseconds
    
    if ping -c "$count" -W "$timeout" "$ip_address" >/dev/null 2>&1; then
        local end_time
        end_time=$(date +%s%3N)
        response_time=$((end_time - start_time))
        
        if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
            echo -e "${GREEN}[DEBUG] Ping successful: $ip_address (${response_time}ms)${NC}" >&2
        fi
        
        echo "$response_time"  # Return response time
        return 0
    else
        if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
            echo -e "${RED}[DEBUG] Ping failed: $ip_address${NC}" >&2
        fi
        return 1
    fi
}

# Get MAC address from ARP table
get_mac_address() {
    local ip_address="$1"
    local timeout="${2:-$DEFAULT_ARP_TIMEOUT}"
    
    if [[ -z "$ip_address" ]]; then
        echo -e "${RED}Error: IP address is required${NC}" >&2
        return 1
    fi
    
    local mac_address=""
    
    # Try multiple methods to get MAC address
    # Method 1: Traditional arp command
    if command -v arp >/dev/null 2>&1; then
        mac_address=$(arp -n "$ip_address" 2>/dev/null | awk 'NR==1 {print $3}' | grep -E '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || true)
    fi
    
    # Method 2: ip neigh command (modern Linux)
    if [[ -z "$mac_address" ]] && command -v ip >/dev/null 2>&1; then
        mac_address=$(ip neigh show "$ip_address" 2>/dev/null | awk '{print $5}' | grep -E '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' | head -1 || true)
    fi
    
    # Method 3: Parse /proc/net/arp (Linux specific)
    if [[ -z "$mac_address" ]] && [[ -f /proc/net/arp ]]; then
        mac_address=$(awk -v ip="$ip_address" '$1 == ip {print $4}' /proc/net/arp 2>/dev/null | grep -E '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' | head -1 || true)
    fi
    
    if [[ -n "$mac_address" ]]; then
        # Convert to lowercase for consistency
        mac_address=$(echo "$mac_address" | tr '[:upper:]' '[:lower:]')
        
        if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
            echo -e "${GREEN}[DEBUG] MAC found for $ip_address: $mac_address${NC}" >&2
        fi
        
        echo "$mac_address"
        return 0
    else
        if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
            echo -e "${YELLOW}[DEBUG] No MAC address found for $ip_address${NC}" >&2
        fi
        return 1
    fi
}

# Validate MAC address against expected value
validate_mac_address() {
    local ip_address="$1"
    local expected_mac="$2"
    local timeout="${3:-$DEFAULT_ARP_TIMEOUT}"
    
    if [[ -z "$ip_address" || -z "$expected_mac" ]]; then
        echo -e "${RED}Error: IP address and expected MAC are required${NC}" >&2
        return 1
    fi
    
    # Normalize expected MAC to lowercase
    expected_mac=$(echo "$expected_mac" | tr '[:upper:]' '[:lower:]')
    
    # Get actual MAC address
    local actual_mac
    if actual_mac=$(get_mac_address "$ip_address" "$timeout"); then
        if [[ "$actual_mac" == "$expected_mac" ]]; then
            if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
                echo -e "${GREEN}[DEBUG] MAC validation successful: $ip_address ($actual_mac)${NC}" >&2
            fi
            echo "$actual_mac"  # Return actual MAC
            return 0
        else
            if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
                echo -e "${RED}[DEBUG] MAC mismatch: $ip_address expected=$expected_mac actual=$actual_mac${NC}" >&2
            fi
            echo "$actual_mac"  # Return actual MAC even if it doesn't match
            return 1
        fi
    else
        if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
            echo -e "${YELLOW}[DEBUG] MAC validation failed: no ARP entry for $ip_address${NC}" >&2
        fi
        return 1
    fi
}

# Force refresh ARP cache for an IP
refresh_arp_cache() {
    local ip_address="$1"
    local timeout="${2:-2}"
    
    if [[ -z "$ip_address" ]]; then
        echo -e "${RED}Error: IP address is required${NC}" >&2
        return 1
    fi
    
    # Try arping if available (most reliable)
    if command -v arping >/dev/null 2>&1; then
        if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
            echo -e "${BLUE}[DEBUG] Refreshing ARP cache with arping: $ip_address${NC}" >&2
        fi
        arping -c 1 -w "$timeout" "$ip_address" >/dev/null 2>&1 || true
        return 0
    fi
    
    # Fallback: ping to populate ARP cache
    if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
        echo -e "${BLUE}[DEBUG] Refreshing ARP cache with ping: $ip_address${NC}" >&2
    fi
    ping -c 1 -W "$timeout" "$ip_address" >/dev/null 2>&1 || true
    
    # Small delay to let ARP cache populate
    sleep 0.5
}

# Comprehensive switch authenticity check (ping + MAC validation)
check_switch_authentic() {
    local ip_address="$1"
    local expected_mac="$2"
    local ping_timeout="${3:-$DEFAULT_PING_TIMEOUT}"
    local arp_timeout="${4:-$DEFAULT_ARP_TIMEOUT}"
    local label="${5:-$ip_address}"
    local room="${6:-unknown}"
    
    if [[ -z "$ip_address" || -z "$expected_mac" ]]; then
        echo -e "${RED}Error: IP address and expected MAC are required${NC}" >&2
        return 1
    fi
    
    local ping_successful=false
    local mac_validated=false
    local is_authentic=false
    local alternative_method_used=false
    local response_time=""
    local actual_mac=""
    
    # Stage 1: Ping test
    if response_time=$(ping_switch "$ip_address" "$ping_timeout"); then
        ping_successful=true
        
        # Stage 2: MAC validation (when ping succeeds)
        if actual_mac=$(validate_mac_address "$ip_address" "$expected_mac" "$arp_timeout"); then
            mac_validated=true
            is_authentic=true
        else
            # MAC validation failed, but we might have gotten the actual MAC
            if ! actual_mac=$(get_mac_address "$ip_address" "$arp_timeout"); then
                actual_mac=""
            fi
        fi
    else
        # Stage 3: Alternative checking methods when ping fails
        if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
            echo -e "${BLUE}[DEBUG] Ping failed for $ip_address, trying alternative methods${NC}" >&2
        fi
        
        # Method 1: Check if device exists in ARP table with correct MAC
        alternative_method_used=true
        
        # Show user that we're using alternative detection
        if [[ "${POWER_MONITOR_NON_INTERACTIVE:-false}" == "true" ]]; then
            echo "INFO: $label ($ip_address, $room) not responding to ping, checking ARP table" >&2
        else
            echo -e "${YELLOW}⚠ $label ($ip_address, $room) not responding to ping, checking ARP table...${NC}" >&2
        fi
        
        if actual_mac=$(validate_mac_address "$ip_address" "$expected_mac" "$arp_timeout"); then
            mac_validated=true
            is_authentic=true
            
            # Inform user of successful alternative detection
            if [[ "${POWER_MONITOR_NON_INTERACTIVE:-false}" == "true" ]]; then
                echo "INFO: $label ($ip_address, $room) detected via ARP table (ping failed but MAC verified)" >&2
            else
                echo -e "${GREEN}✓ $label ($ip_address, $room) detected via ARP table (ping failed but MAC verified)${NC}" >&2
            fi
            
            if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
                echo -e "${GREEN}[DEBUG] Alternative check successful: $ip_address found in ARP table with correct MAC${NC}" >&2
            fi
        else
            # Method 2: Try to refresh ARP cache and check again
            if [[ "${POWER_MONITOR_NON_INTERACTIVE:-false}" == "true" ]]; then
                echo "INFO: Refreshing ARP cache for $label ($ip_address, $room)" >&2
            else
                echo -e "${BLUE}⟳ Refreshing ARP cache for $label ($ip_address, $room)...${NC}" >&2
            fi
            
            if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
                echo -e "${BLUE}[DEBUG] Refreshing ARP cache for $ip_address${NC}" >&2
            fi
            refresh_arp_cache "$ip_address" 3
            
            if actual_mac=$(validate_mac_address "$ip_address" "$expected_mac" "$arp_timeout"); then
                mac_validated=true
                is_authentic=true
                
                # Inform user of successful detection after ARP refresh
                if [[ "${POWER_MONITOR_NON_INTERACTIVE:-false}" == "true" ]]; then
                    echo "INFO: $label ($ip_address, $room) detected after ARP refresh (ping failed but MAC verified)" >&2
                else
                    echo -e "${GREEN}✓ $label ($ip_address, $room) detected after ARP refresh (ping failed but MAC verified)${NC}" >&2
                fi
                
                if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
                    echo -e "${GREEN}[DEBUG] Alternative check successful after ARP refresh: $ip_address${NC}" >&2
                fi
            else
                # Get actual MAC even if validation failed (for debugging)
                if ! actual_mac=$(get_mac_address "$ip_address" "$arp_timeout"); then
                    actual_mac=""
                fi
                
                # Inform user that all methods failed
                if [[ "${POWER_MONITOR_NON_INTERACTIVE:-false}" == "true" ]]; then
                    echo "WARNING: $label ($ip_address, $room) not reachable via ping or ARP table" >&2
                else
                    echo -e "${RED}✗ $label ($ip_address, $room) not reachable via ping or ARP table${NC}" >&2
                fi
                
                if [[ -n "${POWER_MONITOR_DEBUG:-}" ]]; then
                    echo -e "${YELLOW}[DEBUG] All alternative methods failed for $ip_address${NC}" >&2
                fi
            fi
        fi
    fi
    
    # Output results in structured format
    echo "ping_successful:$ping_successful"
    echo "mac_validated:$mac_validated"
    echo "is_authentic:$is_authentic"
    echo "alternative_method_used:$alternative_method_used"
    echo "response_time:$response_time"
    echo "actual_mac:$actual_mac"
    
    # Return 0 if authentic, 1 otherwise
    if [[ "$is_authentic" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# Check multiple switches in parallel
check_switches_parallel() {
    local switches_data="$1"  # JSON array of switch objects
    local max_jobs="${2:-10}"
    local ping_timeout="${3:-$DEFAULT_PING_TIMEOUT}"
    local arp_timeout="${4:-$DEFAULT_ARP_TIMEOUT}"
    
    if [[ -z "$switches_data" ]]; then
        echo -e "${RED}Error: Switches data is required${NC}" >&2
        return 1
    fi
    
    # Create temporary directory for parallel job results
    local temp_dir
    temp_dir=$(mktemp -d)
    local job_pids=()
    local job_count=0
    
    # Parse switches and start parallel jobs
    while IFS= read -r switch_json; do
        if [[ -z "$switch_json" || "$switch_json" == "null" ]]; then
            continue
        fi
        
        local label ip_address expected_mac location
        label=$(echo "$switch_json" | jq -r '.label // empty')
        ip_address=$(echo "$switch_json" | jq -r '."ip-address" // ."ip_address" // empty')
        expected_mac=$(echo "$switch_json" | jq -r '."mac-address" // ."mac_address" // empty')
        location=$(echo "$switch_json" | jq -r '.location // .room // empty')
        
        if [[ -z "$label" || -z "$ip_address" || -z "$expected_mac" ]]; then
            echo -e "${YELLOW}Warning: Skipping incomplete switch config: $switch_json${NC}" >&2
            continue
        fi
        
        # Wait if we've reached max parallel jobs
        if [[ ${#job_pids[@]} -ge $max_jobs ]]; then
            wait "${job_pids[0]}"
            job_pids=("${job_pids[@]:1}")  # Remove first element
        fi
        
        # Start parallel job
        (
            result=$(check_switch_authentic "$ip_address" "$expected_mac" "$ping_timeout" "$arp_timeout" "$label" "$location")
            echo "switch_label:$label" > "$temp_dir/job_$job_count"
            echo "ip_address:$ip_address" >> "$temp_dir/job_$job_count"
            echo "expected_mac:$expected_mac" >> "$temp_dir/job_$job_count"
            echo "$result" >> "$temp_dir/job_$job_count"
        ) &
        
        job_pids+=($!)
        ((job_count++))
        
    done < <(echo "$switches_data" | jq -c '.[]')
    
    # Wait for all remaining jobs to complete
    for pid in "${job_pids[@]}"; do
        wait "$pid"
    done
    
    # Collect and output results
    for ((i=0; i<job_count; i++)); do
        if [[ -f "$temp_dir/job_$i" ]]; then
            echo "---"  # Separator for each switch result
            cat "$temp_dir/job_$i"
        fi
    done
    
    # Cleanup
    rm -rf "$temp_dir"
}

# Check switches with progress indication (using gum if available)
check_switches_with_progress() {
    local switches_data="$1"
    local ping_timeout="${2:-$DEFAULT_PING_TIMEOUT}"
    local arp_timeout="${3:-$DEFAULT_ARP_TIMEOUT}"
    
    if [[ -z "$switches_data" ]]; then
        echo -e "${RED}Error: Switches data is required${NC}" >&2
        return 1
    fi
    
    local total_switches
    total_switches=$(echo "$switches_data" | jq '. | length')
    
    if [[ "$total_switches" -eq 0 ]]; then
        echo -e "${YELLOW}No switches to check${NC}" >&2
        return 0
    fi
    
    # Initial progress message
    if [[ "${POWER_MONITOR_NON_INTERACTIVE:-false}" == "true" ]]; then
        echo "Checking $total_switches switches..." >&2
    else
        echo -e "${BLUE}Checking $total_switches switches...${NC}" >&2
    fi
    
    local current_switch=0
    
    while IFS= read -r switch_json; do
        if [[ -z "$switch_json" || "$switch_json" == "null" ]]; then
            continue
        fi
        
        ((current_switch++))
        
        local label ip_address expected_mac location
        label=$(echo "$switch_json" | jq -r '.label // empty')
        ip_address=$(echo "$switch_json" | jq -r '."ip-address" // ."ip_address" // empty')
        expected_mac=$(echo "$switch_json" | jq -r '."mac-address" // ."mac_address" // empty')
        location=$(echo "$switch_json" | jq -r '.location // .room // empty')
        
        if [[ -z "$label" || -z "$ip_address" || -z "$expected_mac" ]]; then
            echo -e "${YELLOW}Warning: Skipping incomplete switch config: $switch_json${NC}" >&2
            continue
        fi
        
        # Check switch first to get result
        local check_result
        check_result=$(check_switch_authentic "$ip_address" "$expected_mac" "$ping_timeout" "$arp_timeout" "$label" "$location")
        local is_authentic
        is_authentic=$(echo "$check_result" | grep "is_authentic:" | cut -d: -f2)
        
        # Show progress with status indicator
        local status_icon status_text
        if [[ "$is_authentic" == "true" ]]; then
            status_icon="✓"
            status_text="OK"
        else
            status_icon="✗"
            status_text="FAIL"
        fi
        
        # Check if running in non-interactive mode (cron, headless)
        if [[ "${POWER_MONITOR_NON_INTERACTIVE:-false}" == "true" ]]; then
            # Non-interactive mode: plain text, no colors, no emojis
            echo "[$current_switch/$total_switches] $label ($ip_address): $status_text" >&2
        else
            # Interactive mode: colors and visual indicators
            if [[ "$is_authentic" == "true" ]]; then
                if command -v gum >/dev/null 2>&1; then
                    echo -e "Checking $label ($current_switch/$total_switches)... ${GREEN}${status_icon}${NC}" >&2
                else
                    echo -e "${BLUE}[$current_switch/$total_switches] Checking $label ($ip_address)...${NC} ${GREEN}${status_icon}${NC}" >&2
                fi
            else
                if command -v gum >/dev/null 2>&1; then
                    echo -e "Checking $label ($current_switch/$total_switches)... ${RED}${status_icon}${NC}" >&2
                else
                    echo -e "${BLUE}[$current_switch/$total_switches] Checking $label ($ip_address)...${NC} ${RED}${status_icon}${NC}" >&2
                fi
            fi
        fi
        
        # Output results
        echo "---"  # Separator
        echo "switch_label:$label"
        echo "ip_address:$ip_address"
        echo "expected_mac:$expected_mac"
        echo "$check_result"
        
    done < <(echo "$switches_data" | jq -c '.[]')
    
    # Completion message
    if [[ "${POWER_MONITOR_NON_INTERACTIVE:-false}" == "true" ]]; then
        echo "Switch checking completed" >&2
    else
        echo -e "${GREEN}Switch checking completed${NC}" >&2
    fi
}

# Network diagnostic functions

# Test basic network connectivity
test_network_connectivity() {
    echo -e "${BLUE}Testing network connectivity...${NC}"
    
    # Test DNS resolution
    if ping -c 1 -W 2 google.com >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Internet connectivity: OK${NC}"
    else
        echo -e "${YELLOW}⚠ Internet connectivity: Limited or none${NC}"
    fi
    
    # Test local gateway
    local gateway
    if command -v ip >/dev/null 2>&1; then
        gateway=$(ip route show default | awk '/default/ {print $3}' | head -1)
    elif command -v route >/dev/null 2>&1; then
        gateway=$(route -n | awk '/^0.0.0.0/ {print $2}' | head -1)
    fi
    
    if [[ -n "$gateway" ]]; then
        if ping -c 1 -W 2 "$gateway" >/dev/null 2>&1; then
            echo -e "${GREEN}✓ Gateway connectivity ($gateway): OK${NC}"
        else
            echo -e "${RED}✗ Gateway connectivity ($gateway): Failed${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ Could not determine gateway${NC}"
    fi
    
    # Test ARP functionality
    if command -v arp >/dev/null 2>&1; then
        local arp_entries
        arp_entries=$(arp -a 2>/dev/null | wc -l)
        echo -e "${GREEN}✓ ARP table: $arp_entries entries${NC}"
    elif command -v ip >/dev/null 2>&1; then
        local arp_entries
        arp_entries=$(ip neigh show 2>/dev/null | wc -l)
        echo -e "${GREEN}✓ Neighbor table: $arp_entries entries${NC}"
    else
        echo -e "${RED}✗ No ARP/neighbor table access${NC}"
    fi
}

# Show ARP/neighbor table
show_arp_table() {
    echo -e "${BLUE}ARP/Neighbor table:${NC}"
    
    if command -v arp >/dev/null 2>&1; then
        arp -a 2>/dev/null | sort
    elif command -v ip >/dev/null 2>&1; then
        ip neigh show 2>/dev/null | sort
    else
        echo -e "${RED}No ARP table access available${NC}"
    fi
}

# Network scanning functions

# Scan local network for active devices
scan_local_network() {
    local network="${1:-}"
    local timeout="${2:-2}"
    
    # Auto-detect network if not provided
    if [[ -z "$network" ]]; then
        if command -v ip >/dev/null 2>&1; then
            network=$(ip route show | awk '/scope link/ {print $1}' | head -1)
        fi
    fi
    
    if [[ -z "$network" ]]; then
        echo -e "${RED}Could not determine local network${NC}" >&2
        return 1
    fi
    
    echo -e "${BLUE}Scanning network: $network${NC}"
    
    # Use nmap if available, otherwise fall back to ping sweep
    if command -v nmap >/dev/null 2>&1; then
        nmap -sn "$network" 2>/dev/null | grep -E "(Nmap scan report|MAC Address)"
    else
        echo -e "${YELLOW}nmap not available, using ping sweep${NC}"
        
        # Extract network base and scan common IPs
        local base_ip
        base_ip=$(echo "$network" | cut -d'/' -f1 | cut -d'.' -f1-3)
        
        for i in {1..254}; do
            local ip="$base_ip.$i"
            if ping -c 1 -W "$timeout" "$ip" >/dev/null 2>&1; then
                echo "Host is up: $ip"
            fi
        done
    fi
}

# Find devices with specific MAC vendor
find_devices_by_vendor() {
    local vendor_pattern="$1"
    
    if [[ -z "$vendor_pattern" ]]; then
        echo -e "${RED}Error: Vendor pattern is required${NC}" >&2
        return 1
    fi
    
    echo -e "${BLUE}Finding devices with vendor pattern: $vendor_pattern${NC}"
    
    if command -v arp >/dev/null 2>&1; then
        arp -a 2>/dev/null | grep -i "$vendor_pattern"
    elif command -v ip >/dev/null 2>&1; then
        ip neigh show 2>/dev/null | grep -i "$vendor_pattern"
    else
        echo -e "${RED}No ARP table access available${NC}"
        return 1
    fi
}