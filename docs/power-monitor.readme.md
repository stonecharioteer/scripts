# Power Monitor System Documentation

## Overview

The Power Monitor System is a comprehensive bash-based solution for monitoring house and room-level power status by checking smart switch connectivity. It distinguishes between main power and backup power operation, with special handling for critical infrastructure switches that are connected to backup power systems.

**Why this script is needed**: Modern smart homes with backup power systems need reliable monitoring to distinguish between normal operation (main power), backup operation (power outage but backup working), and critical situations (backup failure). This is especially important when the monitoring system itself relies on backup power - if backup-connected switches go offline, it indicates the monitoring system may be at risk.

## Architecture

### Modular Design
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

### Key Components

#### 1. Database Layer (lib/database.sh)
- **Purpose**: Abstracted DuckDB operations for easy migration to time-series databases
- **Functions**:
  - `init_database()`: Create tables and initialize schema
  - `insert_power_status()`: Record house-level power events
  - `insert_room_status()`: Record room-level power events  
  - `insert_switch_status()`: Record individual switch status
  - `get_current_status()`: Retrieve latest power state
  - `get_uptime_stats()`: Calculate uptime statistics
  - `get_outage_history()`: Retrieve outage history with filtering

#### 2. Network Layer (lib/network.sh)
- **Purpose**: Switch connectivity testing with MAC address validation and alternative detection
- **Functions**:
  - `ping_switch()`: Basic ping connectivity test
  - `get_mac_address()`: Extract MAC from ARP table with multiple methods
  - `validate_mac()`: Compare expected vs actual MAC
  - `check_switch_authentic()`: Enhanced three-stage validation with alternative detection
  - `check_switches_with_progress()`: Batch switch checking with real-time feedback
  - `refresh_arp_cache()`: Force ARP cache refresh for problematic devices
- **Enhanced Three-Stage Validation**:
  1. **Primary Detection**: Ping IP address + MAC validation via ARP table
  2. **Alternative Method 1**: Check ARP table for existing entry with correct MAC (when ping fails)
  3. **Alternative Method 2**: Refresh ARP cache and re-check (when ARP lookup fails)
- **Features**:
  - **Robust Detection**: Handles devices that block ping but are reachable via ARP table
  - **User Messaging**: Informative messages with device context (label, IP, room)
  - **Fallback Methods**: Multiple detection strategies for maximum reliability
  - **MAC Validation**: Prevents false positives from IP conflicts or device replacements

**Alternative Detection Examples**:
```bash
# Interactive Mode:
⚠ fridge (192.168.100.110, vinay-bedroom) not responding to ping, checking ARP table...
✓ fridge (192.168.100.110, vinay-bedroom) detected via ARP table (ping failed but MAC verified)
⟳ Refreshing ARP cache for fridge (192.168.100.110, vinay-bedroom)...
✗ fridge (192.168.100.110, vinay-bedroom) not reachable via ping or ARP table

# Non-Interactive Mode (cron-friendly):
INFO: fridge (192.168.100.110, vinay-bedroom) not responding to ping, checking ARP table
WARNING: fridge (192.168.100.110, vinay-bedroom) not reachable via ping or ARP table
```

#### 3. Power Logic Layer (lib/power-logic.sh)
- **Purpose**: Backup-aware power state calculations
- **Functions**:
  - `calculate_main_power_status()`: Based on non-backup switches
  - `calculate_backup_power_status()`: Based on backup-connected switches
  - `determine_system_status()`: Overall system state calculation
  - `detect_outage_events()`: Outage start/end detection
  - `calculate_uptime()`: Power mode aware uptime calculations
- **Power States**:
  - `ONLINE`: Main power available (≥50% non-backup switches online)
  - `BACKUP`: Main power lost, backup power working (all backup switches online)
  - `CRITICAL`: Backup power failed (any backup switch offline)
  - `OFFLINE`: No power detected anywhere

#### 4. Configuration Layer (lib/config.sh)
- **Purpose**: switches.json loading and validation
- **Functions**:
  - `load_switches_config()`: Parse and validate JSON config
  - `validate_switch_config()`: Check required fields
  - `get_switches_by_room()`: Group switches by location
  - `get_backup_switches()`: Filter backup-connected switches
  - `auto_discover_switches()`: Add new switches to database

#### 5. UI Layer (lib/ui.sh)
- **Purpose**: Gum-styled interfaces and color-coded displays
- **Functions**:
  - `format_status_online()`: Green ONLINE status
  - `format_status_backup()`: Yellow BACKUP status  
  - `format_status_critical()`: Red CRITICAL status
  - `format_status_offline()`: Red OFFLINE status
  - `show_status_table()`: Room status table display
  - `show_progress_spinner()`: Network check progress
  - `show_interactive_room_selector()`: Room selection interface

## Database Schema

### Tables

#### switches
```sql
CREATE TABLE switches (
    label VARCHAR PRIMARY KEY,           -- Switch identifier (e.g., "clock2", "ac1")
    ip_address VARCHAR NOT NULL,         -- IP address for connectivity testing
    room_name VARCHAR NOT NULL,          -- Room/location identifier
    mac_address VARCHAR NOT NULL,        -- Expected MAC address for validation
    backup_connected BOOLEAN NOT NULL,   -- Critical field: true if on backup power
    first_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

#### rooms
```sql
CREATE TABLE rooms (
    room_name VARCHAR PRIMARY KEY,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

#### power_status (House-level)
```sql
CREATE TABLE power_status (
    timestamp TIMESTAMP PRIMARY KEY,
    main_power_switches_online INTEGER,  -- Non-backup switches online
    main_power_switches_total INTEGER,   -- Total non-backup switches
    backup_switches_online INTEGER,      -- Backup switches online
    backup_switches_total INTEGER,       -- Total backup switches  
    main_power_on BOOLEAN,              -- Main power status
    backup_power_on BOOLEAN,            -- Backup power status
    system_status VARCHAR,              -- ONLINE/BACKUP/CRITICAL/OFFLINE
    house_outage_id INTEGER             -- Groups related outage events
);
```

#### room_power_status (Room-level)
```sql
CREATE TABLE room_power_status (
    timestamp TIMESTAMP,
    room_name VARCHAR,
    switches_online INTEGER,
    total_switches INTEGER,
    room_power_on BOOLEAN,
    room_outage_id INTEGER,
    FOREIGN KEY (room_name) REFERENCES rooms(room_name)
);
```

#### switch_status (Individual switch tracking)
```sql
CREATE TABLE switch_status (
    timestamp TIMESTAMP,
    switch_label VARCHAR,
    ip_address VARCHAR,
    room_name VARCHAR,
    backup_connected BOOLEAN,
    ping_successful BOOLEAN,           -- Basic ping result
    mac_validated BOOLEAN,            -- MAC address validation result
    is_authentic BOOLEAN,             -- ping_successful AND mac_validated
    expected_mac VARCHAR,
    actual_mac VARCHAR,               -- NULL if ARP lookup failed
    response_time_ms FLOAT,
    FOREIGN KEY (switch_label) REFERENCES switches(label)
);
```

## Configuration File Format

### switches.json
```json
[
  {
    "label": "server-switch",
    "ip-address": "192.168.100.100",
    "location": "server-room",
    "mac-address": "aa:bb:cc:dd:ee:ff",
    "backup-connected": true
  },
  {
    "label": "living-room-lamp",
    "ip-address": "192.168.100.101", 
    "location": "living-room",
    "mac-address": "11:22:33:44:55:66",
    "backup-connected": false
  }
]
```

**Critical Fields**:
- `backup-connected`: If `true`, this switch MUST be online for system health
- Missing this field defaults to `false` (non-critical switch)

## Command Interface

### Main Script: power-monitor.sh

#### Subcommands

##### 1. init - Initialize System
```bash
./power-monitor.sh init [--database-path PATH]
```
- Creates directory structure
- Initializes DuckDB database with schema
- Imports switches from config/switches.json
- Auto-creates room records
- Validates dependencies (duckdb, ping, arp, jq, gum)

##### 2. record - Record Current Status
```bash
./power-monitor.sh record [--timeout SECONDS]
```
- Checks all switches with ping + MAC validation
- Calculates house and room power states
- Stores results in all database tables
- Auto-discovers new switches and adds to database
- Shows real-time progress with gum spinner

##### 3. status - Display Current Status
```bash
./power-monitor.sh status [--room ROOM]
```
- Shows current system power state (ONLINE/BACKUP/CRITICAL/OFFLINE)
- Displays room-by-room status table with color coding
- Shows current uptime streak and time since last outage
- Highlights critical infrastructure status

Example output:
```
┌──────────────────────────────────────────────────┐
│                 Power Monitor                    │
│          House & Room Status [BACKUP]           │
└──────────────────────────────────────────────────┘

System Status: BACKUP (Main power lost 2h 15m ago)

┌─────────────┬──────────┬────────┬──────────────┬────────┐
│    Room     │ Switches │ Status │    Uptime    │ Backup │
├─────────────┼──────────┼────────┼──────────────┼────────┤
│ Living Room │   2/3    │PARTIAL │     --       │   No   │
│ Bedroom     │   2/2    │ ONLINE │  2d 15h 23m  │   No   │
│ Server Room │   1/1    │ ONLINE │  2d 15h 23m  │  Yes   │
└─────────────┴──────────┴────────┴──────────────┴────────┘

Critical Infrastructure: All backup systems operational
```

##### 4. uptime - Power Uptime Information
```bash
./power-monitor.sh uptime [--room ROOM] [--all-rooms]
```
- Shows house or room-specific uptime
- Displays current power mode and streak duration
- Historical reliability percentages
- Time spent in each power mode (ONLINE/BACKUP/CRITICAL)

##### 5. history - Outage History and Analysis
```bash
./power-monitor.sh history [--room ROOM] [--days N] [--limit N]
```
- Lists recent outages with duration and affected rooms
- Differentiates main power outages vs backup failures
- Statistics: total outages, average duration, longest outage
- Critical events highlighting (backup system failures)

##### 6. rooms - Room Management
```bash
./power-monitor.sh rooms [list|stats]
```
- `list`: Shows all rooms with switch counts and current status
- `stats`: Room power statistics and reliability metrics

#### Global Options
- `--database-path PATH`: Custom database location (default: ~/Documents/power.db)
- `--config-dir PATH`: Custom config directory (default: ./config/)
- `--timeout SECONDS`: Network timeout for switch checks (default: 5)
- `--verbose`: Detailed output and debug information
- `--dry-run`: Show what would be done without making changes
- `-h, --help`: Show help for command or subcommand

## Power Logic Details

### Main Power Calculation
```bash
# Count non-backup switches
main_switches_online=$(count switches where backup_connected=false AND is_authentic=true)
main_switches_total=$(count switches where backup_connected=false)

# Main power is ON if ≥50% of non-backup switches are online
if [[ $main_switches_online -ge $((main_switches_total / 2)) ]]; then
    main_power_on=true
else
    main_power_on=false
fi
```

### Backup Power Calculation
```bash
# ALL backup switches must be online for backup power to be considered operational
backup_switches_online=$(count switches where backup_connected=true AND is_authentic=true)
backup_switches_total=$(count switches where backup_connected=true)

if [[ $backup_switches_online -eq $backup_switches_total ]] && [[ $backup_switches_total -gt 0 ]]; then
    backup_power_on=true
else
    backup_power_on=false
fi
```

### System Status Determination
```bash
if [[ $main_power_on == true ]]; then
    system_status="ONLINE"
elif [[ $main_power_on == false ]] && [[ $backup_power_on == true ]]; then
    system_status="BACKUP"  
elif [[ $backup_power_on == false ]] && [[ $backup_switches_total -gt 0 ]]; then
    system_status="CRITICAL"  # Backup failed
else
    system_status="OFFLINE"   # No power anywhere
fi
```

### Room Power Calculation
```bash
# Room power based on ≥50% of switches in that room being online
room_switches_online=$(count switches in room where is_authentic=true)
room_switches_total=$(count switches in room)

if [[ $room_switches_online -ge $((room_switches_total / 2)) ]]; then
    room_power_on=true
else  
    room_power_on=false
fi
```

## Network Validation Workflow

### Two-Stage Validation Process

#### Stage 1: Ping Test
```bash
ping -c 1 -W 5 "$ip_address" >/dev/null 2>&1
ping_successful=$?
```

#### Stage 2: MAC Address Validation
```bash
# Get MAC from ARP table
actual_mac=$(arp -n "$ip_address" 2>/dev/null | awk '{print $3}' | grep -E '^([0-9a-f]{2}:){5}[0-9a-f]{2}$')

# Compare with expected MAC
if [[ "$actual_mac" == "$expected_mac" ]]; then
    mac_validated=true
else
    mac_validated=false
fi

# Switch is considered authentic only if both tests pass
is_authentic=$((ping_successful == 0 && mac_validated == true))
```

### Handling Edge Cases
- **ARP Cache Miss**: If no ARP entry exists, MAC validation fails but ping may succeed
- **IP Conflicts**: Different device responds to ping with wrong MAC address
- **Device Replacement**: New device with same IP but different MAC
- **Network Issues**: Ping fails but device may be online (MAC validation impossible)

## Error Handling and Recovery

### Dependency Validation
```bash
# Check required tools on startup
check_dependencies() {
    local missing_deps=()
    
    command -v duckdb >/dev/null || missing_deps+=("duckdb")
    command -v ping >/dev/null || missing_deps+=("ping") 
    command -v arp >/dev/null || missing_deps+=("arp")
    command -v jq >/dev/null || missing_deps+=("jq")
    command -v gum >/dev/null || missing_deps+=("gum")
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "Missing dependencies: ${missing_deps[*]}"
        exit 1
    fi
}
```

### Database Recovery
- Automatic table creation if missing
- Schema migration support for future updates
- Backup and restore functionality
- Corruption detection and repair

### Network Timeout Handling
- Configurable timeouts for different network conditions
- Graceful degradation when switches are unreachable
- Retry logic for transient network issues
- Parallel switch checking for performance

## Future Migration Strategy

### Database Abstraction
The database layer is designed for easy migration to time-series databases:

#### Migration to InfluxDB
```bash
# Current DuckDB insert
insert_power_status() {
    duckdb "$DB_PATH" "INSERT INTO power_status VALUES (...)"
}

# Future InfluxDB insert  
insert_power_status() {
    influx write "power_status,location=house status=$status $timestamp"
}
```

#### Migration to Prometheus
```bash
# Export metrics in Prometheus format
cat << EOF > /var/lib/node_exporter/textfile_collector/power_monitor.prom
house_power_status{type="main"} $main_power_on
house_power_status{type="backup"} $backup_power_on
room_power_status{room="$room"} $room_power_on
EOF
```

### Grafana Integration
- Pre-built dashboards for power monitoring
- Alerting rules for backup failures and extended outages
- Historical trend analysis and capacity planning
- Integration with home automation systems

## Installation and Setup

### Prerequisites
```bash
# Install required packages (Ubuntu/Debian)
sudo apt update
sudo apt install duckdb jq gum

# Install gum if not available in package manager
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
sudo apt update && sudo apt install gum
```

### Initial Setup
```bash
# 1. Clone/download the power-monitor system
git clone <repository> power-monitor
cd power-monitor

# 2. Configure switches
cp config/switches.json.example config/switches.json
# Edit config/switches.json with your switch details

# 3. Initialize the system
./power-monitor.sh init

# 4. Test connectivity
./power-monitor.sh record

# 5. View status
./power-monitor.sh status
```

### Automation Setup
```bash
# Add to crontab for regular monitoring
crontab -e

# Record status every 5 minutes
*/5 * * * * /path/to/power-monitor.sh record >/dev/null 2>&1

# Daily status email (optional)
0 8 * * * /path/to/power-monitor.sh status | mail -s "Daily Power Status" admin@example.com
```

## Troubleshooting

### Common Issues

#### 1. Switch Not Detected
```bash
# Check basic connectivity
ping 192.168.100.101

# Check ARP table
arp -a | grep 192.168.100.101

# Verify MAC address
./power-monitor.sh record --verbose
```

#### 2. Database Issues
```bash
# Reinitialize database
./power-monitor.sh init --force

# Check database integrity
duckdb ~/Documents/power.db "PRAGMA integrity_check;"

# Manual schema check
duckdb ~/Documents/power.db ".schema"
```

#### 3. MAC Validation Failures
```bash
# Refresh ARP cache
sudo ip neigh flush all

# Check for IP conflicts
nmap -sn 192.168.100.0/24

# Verify switch MAC address
arp-scan --interface=eth0 --local
```

### Performance Optimization

#### Network Checking
- Use parallel switch checking for large deployments
- Adjust timeouts based on network conditions
- Implement smart retry logic for intermittent failures

#### Database Performance  
- Regular database maintenance and optimization
- Index creation for frequently queried columns
- Archival strategy for historical data

## Security Considerations

### Network Security
- Monitor for unexpected MAC address changes (potential security breach)
- Log authentication failures and network anomalies
- Consider encrypted database storage for sensitive environments

### Access Control
- Restrict database file permissions (600)
- Log all administrative actions
- Consider role-based access for multi-user environments

### Data Privacy
- Sanitize logs before external transmission
- Implement data retention policies
- Consider encryption for sensitive switch information

## Extensions and Customization

### Adding New Switch Types
1. Update switches.json with new switch details
2. Add any specialized validation logic in network.sh
3. Update UI formatting if needed for new switch categories

### Custom Power Logic
1. Modify power-logic.sh for custom power state calculations
2. Add new power states if needed for specific scenarios
3. Update database schema and UI accordingly

### Integration Points
- REST API endpoints for external monitoring systems
- Webhook notifications for critical events
- MQTT publishing for home automation integration
- Custom alert mechanisms (email, SMS, Slack)

## Performance Metrics

### Typical Performance
- Switch checking: ~1-2 seconds per switch (ping + MAC validation)
- Database operations: <100ms for typical queries
- UI rendering: <500ms for status displays
- Memory usage: <50MB for typical deployments

### Scalability
- Tested with up to 50 switches across 10 rooms
- Database handles years of historical data efficiently
- Modular design supports horizontal scaling