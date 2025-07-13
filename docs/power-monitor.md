# Power Monitor System

## Purpose

I needed a reliable way to monitor my house power status and distinguish between normal operation, backup power operation, and critical system failures. This is especially important in a smart home setup with backup power systems where certain switches are connected to backup power and must always be online - if they go offline, it indicates the monitoring system itself may be at risk.

## Overview

Comprehensive house and room-level power monitoring system that tracks smart switch connectivity to determine power states with backup-aware logic, MAC address validation, and enhanced network detection.

## Requirements

- `duckdb` for database operations
- `ping` for connectivity testing
- `arp` or `ip` for MAC address validation
- `jq` for JSON processing
- `gum` for beautiful UI (optional, falls back to text mode)

## Architecture

### Modular Design
```
power-monitor/
├── power-monitor.sh           # Main script with subcommands
├── lib/                       # Modular library components
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

### Power States
- **ONLINE** (Green) - Main power available, all systems normal
- **BACKUP** (Yellow) - Running on backup power (main power lost)
- **CRITICAL** (Red) - Backup power failed, system at risk
- **OFFLINE** (Red) - No power detected anywhere

## Key Features

- **Backup-Aware Logic** - Distinguishes main power from backup power switches
- **Enhanced Network Detection** - Three-stage validation: ping → ARP table → ARP refresh with informative user messaging
- **MAC Address Validation** - Prevents false positives from IP conflicts using ARP table verification
- **Alternative Detection** - Detects devices that don't respond to ping but are reachable via ARP table
- **Room-Level Tracking** - Individual room power monitoring and uptime
- **Beautiful UI** - Color-coded status displays with gum styling (fallback to text mode)
- **Database Storage** - DuckDB for historical data with future migration path to Prometheus/InfluxDB
- **Critical Infrastructure Monitoring** - Special handling for backup-connected switches
- **Comprehensive Help** - Full help system for all subcommands
- **Modular Design** - Clean separation for easy testing and maintenance
- **Automation-Friendly** - Non-interactive mode with clean log messages for cron jobs

## Setup

### Initial Configuration

1. **Configure your switches**:
   ```bash
   cp power-monitor/config/switches.json.example power-monitor/config/switches.json
   # Edit switches.json with your actual switch IP addresses, MAC addresses, and locations
   ```

2. **Initialize the system**:
   ```bash
   ./power-monitor/power-monitor.sh init
   ```

3. **Test connectivity**:
   ```bash
   ./power-monitor/power-monitor.sh record
   ```

4. **View status**:
   ```bash
   ./power-monitor/power-monitor.sh status
   ```

### Switch Configuration (switches.json)

```json
[
  {
    "label": "living-room-lamp",
    "ip-address": "192.168.1.100",
    "location": "living-room",
    "mac-address": "aa:bb:cc:dd:ee:01",
    "backup-connected": false
  },
  {
    "label": "server-switch",
    "ip-address": "192.168.1.102",
    "location": "server-room", 
    "mac-address": "aa:bb:cc:dd:ee:03",
    "backup-connected": true
  }
]
```

**Critical Fields:**
- `backup-connected`: If `true`, this switch MUST be online for system health
- Missing this field defaults to `false` (non-critical switch)

## Usage

```bash
# Initialize database and system
./power-monitor.sh init

# Record current power status (check all switches)
./power-monitor.sh record [--timeout SECONDS] [--verbose]

# Display current status with beautiful tables
./power-monitor.sh status [--room ROOM] [--verbose]

# Show uptime information
./power-monitor.sh uptime [--room ROOM] [--all-rooms]

# View outage history and analysis  
./power-monitor.sh history [--days N] [--room ROOM]

# Room management and statistics
./power-monitor.sh rooms [list|stats]

# Test system components
./power-monitor.sh test [config|network|database|power-logic|ui|all]

# Get help for any subcommand
./power-monitor.sh <subcommand> --help
```

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

## Network Validation

### Enhanced Three-Stage Detection

1. **Primary Detection**: Ping IP address + MAC validation via ARP table
2. **Alternative Method 1**: Check ARP table for existing entry with correct MAC (when ping fails)
3. **Alternative Method 2**: Refresh ARP cache and re-check (when ARP lookup fails)

### ARP Freshness Validation

The system validates ARP entries to prevent false positives from stale cache entries:

- **Fresh ARP entries** (REACHABLE/DELAY state) → Device detected as online
- **Stale ARP entries** (STALE/FAILED state) → Device treated as failed/offline
- **Enhanced messaging** with device context (label, IP, room)

### Detection Method Tracking

All device status checks are recorded with numeric detection method codes:

- **0 - FAILED**: Device failed all detection methods or has stale ARP entries
- **1 - PING_ONLY**: Ping successful, MAC validation skipped/failed  
- **2 - PING_MAC**: Ping successful + MAC validation successful (most reliable)
- **3 - ARP_FRESH**: Ping failed, detected via fresh ARP entry (REACHABLE/DELAY state)
- **5 - ARP_REFRESH**: Ping failed, detected after ARP cache refresh
- **6 - ARPING**: Ping failed, detected via arping probe (real-time validation)

### Example Detection Messages

**Interactive Mode:**
```
⚠ fridge (192.168.100.110, kitchen) not responding to ping, checking ARP table...
✓ fridge (192.168.100.110, kitchen) detected via fresh ARP entry (ping failed but MAC verified)
⟳ Refreshing ARP cache for fridge (192.168.100.110, kitchen)...
✗ fridge (192.168.100.110, kitchen) not reachable via ping or ARP table
```

**Non-Interactive Mode (cron-friendly):**
```
INFO: fridge (192.168.100.110, kitchen) not responding to ping, checking ARP table
INFO: fridge (192.168.100.110, kitchen) detected via fresh ARP entry (ping failed but MAC verified)
WARNING: fridge (192.168.100.110, kitchen) not reachable via ping or ARP table
```

## Database Schema

### Core Tables

#### switches
```sql
CREATE TABLE switches (
    label VARCHAR PRIMARY KEY,           -- Switch identifier
    ip_address VARCHAR NOT NULL,         -- IP address for connectivity testing
    room_name VARCHAR NOT NULL,          -- Room/location identifier
    mac_address VARCHAR NOT NULL,        -- Expected MAC address for validation
    backup_connected BOOLEAN NOT NULL,   -- Critical: true if on backup power
    first_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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

#### switch_status (Individual tracking)
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
    detection_method INTEGER NOT NULL DEFAULT 0, -- Detection method used
    FOREIGN KEY (switch_label) REFERENCES switches(label)
);
```

## Automation with Crontab

### Crontab Configuration

For automated monitoring, set up a cron job:

```bash
# Edit your crontab
crontab -e

# Add PATH and monitoring job
PATH=/home/username/.local/bin:/usr/local/bin:/usr/bin:/bin
*/5 * * * * /usr/bin/flock -n /tmp/power-monitor.lock /path/to/power-monitor.sh record 2>&1 | logger -t power-monitor
```

### Important Configuration Details

1. **PATH Environment Variable**: Cron runs with minimal environment. Set PATH to include where `duckdb` is installed.
2. **File Locking with flock**: Use `flock` to prevent multiple instances from running simultaneously.
3. **Logging with logger**: Use `logger` command for automatic log rotation via syslog.

### Monitoring Cron Job Status

```bash
# View real-time power monitor logs
journalctl -t power-monitor -f

# Check recent logs
journalctl -t power-monitor --since "1 hour ago"

# Verify database is being updated
duckdb ~/Documents/power.db -c "SELECT COUNT(*) FROM power_status WHERE DATE(timestamp) = '$(date +%Y-%m-%d)';"
```

## Example Status Output

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

## Recent Bug Fixes

### Room Status Parsing Fix (2025-07-13)

**Issue**: Status command was showing false positives - rooms displayed as "ONLINE" when devices were actually failing connectivity tests.

**Root Cause**: Room data parsing logic used global search (`sed | head -1`) that picked the first match across all rooms instead of parsing each room's data section individually.

**Solution**: Implemented section-by-section parsing that processes each room's data block individually, preventing cross-contamination between room status data.

**Impact**: Eliminated false positive room status reports during actual power outages, ensuring accurate monitoring and reliable alerting foundation.

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

#### 3. Crontab Issues
```bash
# Check if cron jobs are running
grep power-monitor /var/log/syslog | tail -5

# Test exact cron command manually
/usr/bin/flock -n /tmp/power-monitor.lock /path/to/power-monitor.sh record

# Check for PATH issues
journalctl -t power-monitor --since "30 minutes ago"
```

#### 4. MAC Validation Failures
```bash
# Refresh ARP cache
sudo ip neigh flush all

# Check for IP conflicts
nmap -sn 192.168.100.0/24

# Verify switch MAC address
arp-scan --interface=eth0 --local
```

## Performance and Scalability

### Typical Performance
- Switch checking: ~1-2 seconds per switch (ping + MAC validation)
- Database operations: <100ms for typical queries
- UI rendering: <500ms for status displays
- Memory usage: <50MB for typical deployments

### Scalability
- Tested with up to 50 switches across 10 rooms
- Database handles years of historical data efficiently
- Modular design supports horizontal scaling

## Security Considerations

### Network Security
- Monitor for unexpected MAC address changes (potential security breach)
- Log authentication failures and network anomalies
- Consider encrypted database storage for sensitive environments

### Access Control
- Restrict database file permissions (600)
- Log all administrative actions
- Consider role-based access for multi-user environments

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

## Advanced Configuration

### Environment Variables
- `POWER_MONITOR_ARP_REQUIRE_FRESH=true` - Require fresh ARP entries for validation
- `POWER_MONITOR_ARP_FALLBACK_ARPING=false` - Use arping for real-time validation
- `POWER_MONITOR_ARP_DEBUG_LOGGING=false` - Enable detailed ARP debugging

### Custom Power Logic
1. Modify power-logic.sh for custom power state calculations
2. Add new power states if needed for specific scenarios
3. Update database schema and UI accordingly

### Integration Points
- REST API endpoints for external monitoring systems
- Webhook notifications for critical events
- MQTT publishing for home automation integration
- Custom alert mechanisms (email, SMS, Slack)

## Real-World Impact

This system transforms basic smart switch monitoring into enterprise-grade infrastructure monitoring with:

- **Accurate Power Outage Detection**: No false positives from stale ARP cache entries
- **Backup System Monitoring**: Critical distinction between main power loss and backup failure
- **Historical Analysis**: Long-term data collection for trend analysis and capacity planning
- **Automation-Ready**: Clean logging suitable for integration with monitoring dashboards
- **Troubleshooting Capability**: Comprehensive diagnostics and detection method tracking

The enhanced network detection and backup-aware logic make it suitable for critical infrastructure monitoring where power reliability is essential.