-- Power Monitor Database Schema
-- This schema supports backup-aware power monitoring with room-level tracking

-- Rooms table: stores room/location information
CREATE TABLE IF NOT EXISTS rooms (
    room_name VARCHAR PRIMARY KEY,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Switches table: stores switch configuration and metadata
CREATE TABLE IF NOT EXISTS switches (
    label VARCHAR PRIMARY KEY,
    ip_address VARCHAR NOT NULL,
    room_name VARCHAR NOT NULL,
    mac_address VARCHAR NOT NULL,
    backup_connected BOOLEAN NOT NULL DEFAULT false,
    first_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (room_name) REFERENCES rooms(room_name)
);

-- Power status table: house-level power tracking with backup awareness
CREATE TABLE IF NOT EXISTS power_status (
    timestamp TIMESTAMP PRIMARY KEY,
    main_power_switches_online INTEGER NOT NULL,
    main_power_switches_total INTEGER NOT NULL,
    backup_switches_online INTEGER NOT NULL,
    backup_switches_total INTEGER NOT NULL,
    main_power_on BOOLEAN NOT NULL,
    backup_power_on BOOLEAN NOT NULL,
    system_status VARCHAR NOT NULL CHECK (system_status IN ('ONLINE', 'BACKUP', 'CRITICAL', 'OFFLINE')),
    house_outage_id INTEGER
);

-- Room power status table: room-level power tracking
CREATE TABLE IF NOT EXISTS room_power_status (
    timestamp TIMESTAMP NOT NULL,
    room_name VARCHAR NOT NULL,
    switches_online INTEGER NOT NULL,
    total_switches INTEGER NOT NULL,
    room_power_on BOOLEAN NOT NULL,
    room_outage_id INTEGER,
    PRIMARY KEY (timestamp, room_name),
    FOREIGN KEY (room_name) REFERENCES rooms(room_name)
);

-- Switch status table: individual switch connectivity and validation tracking
CREATE TABLE IF NOT EXISTS switch_status (
    timestamp TIMESTAMP NOT NULL,
    switch_label VARCHAR NOT NULL,
    ip_address VARCHAR NOT NULL,
    room_name VARCHAR NOT NULL,
    backup_connected BOOLEAN NOT NULL,
    ping_successful BOOLEAN NOT NULL,
    mac_validated BOOLEAN NOT NULL,
    is_authentic BOOLEAN NOT NULL,
    expected_mac VARCHAR,
    actual_mac VARCHAR,
    response_time_ms FLOAT,
    detection_method INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (timestamp, switch_label),
    FOREIGN KEY (switch_label) REFERENCES switches(label),
    FOREIGN KEY (room_name) REFERENCES rooms(room_name)
);

-- Indexes for performance optimization
CREATE INDEX IF NOT EXISTS idx_power_status_timestamp ON power_status(timestamp);
CREATE INDEX IF NOT EXISTS idx_power_status_system_status ON power_status(system_status);
CREATE INDEX IF NOT EXISTS idx_room_power_status_timestamp ON room_power_status(timestamp);
CREATE INDEX IF NOT EXISTS idx_room_power_status_room ON room_power_status(room_name);
CREATE INDEX IF NOT EXISTS idx_switch_status_timestamp ON switch_status(timestamp);
CREATE INDEX IF NOT EXISTS idx_switch_status_switch ON switch_status(switch_label);
CREATE INDEX IF NOT EXISTS idx_switch_status_room ON switch_status(room_name);
CREATE INDEX IF NOT EXISTS idx_switch_status_detection_method ON switch_status(detection_method);
CREATE INDEX IF NOT EXISTS idx_switches_backup ON switches(backup_connected);
CREATE INDEX IF NOT EXISTS idx_switches_room ON switches(room_name);

-- Views for common queries

-- Current power status view
CREATE VIEW IF NOT EXISTS current_power_status AS
SELECT 
    timestamp,
    system_status,
    main_power_on,
    backup_power_on,
    main_power_switches_online,
    main_power_switches_total,
    backup_switches_online,
    backup_switches_total,
    ROUND((main_power_switches_online * 100.0 / NULLIF(main_power_switches_total, 0)), 1) as main_power_percentage,
    ROUND((backup_switches_online * 100.0 / NULLIF(backup_switches_total, 0)), 1) as backup_power_percentage
FROM power_status 
WHERE timestamp = (SELECT MAX(timestamp) FROM power_status);

-- Current room status view
CREATE VIEW IF NOT EXISTS current_room_status AS
SELECT 
    r.room_name,
    COALESCE(rps.switches_online, 0) as switches_online,
    COALESCE(rps.total_switches, 0) as total_switches,
    COALESCE(rps.room_power_on, false) as room_power_on,
    COALESCE(rps.timestamp, '1970-01-01 00:00:00') as last_update,
    ROUND((COALESCE(rps.switches_online, 0) * 100.0 / NULLIF(COALESCE(rps.total_switches, 0), 0)), 1) as power_percentage
FROM rooms r
LEFT JOIN room_power_status rps ON r.room_name = rps.room_name 
    AND rps.timestamp = (
        SELECT MAX(timestamp) 
        FROM room_power_status rps2 
        WHERE rps2.room_name = r.room_name
    );

-- Current switch status view
CREATE VIEW IF NOT EXISTS current_switch_status AS
SELECT 
    s.label,
    s.ip_address,
    s.room_name,
    s.mac_address,
    s.backup_connected,
    COALESCE(ss.ping_successful, false) as ping_successful,
    COALESCE(ss.mac_validated, false) as mac_validated,
    COALESCE(ss.is_authentic, false) as is_authentic,
    ss.actual_mac,
    ss.response_time_ms,
    COALESCE(ss.detection_method, 0) as detection_method,
    COALESCE(ss.timestamp, '1970-01-01 00:00:00') as last_check
FROM switches s
LEFT JOIN switch_status ss ON s.label = ss.switch_label 
    AND ss.timestamp = (
        SELECT MAX(timestamp) 
        FROM switch_status ss2 
        WHERE ss2.switch_label = s.label
    );

-- Outage summary view
CREATE VIEW IF NOT EXISTS outage_summary AS
WITH outage_periods AS (
    SELECT 
        house_outage_id,
        system_status,
        MIN(timestamp) as outage_start,
        MAX(timestamp) as outage_end,
        COUNT(*) as duration_records
    FROM power_status 
    WHERE house_outage_id IS NOT NULL 
        AND system_status IN ('BACKUP', 'CRITICAL', 'OFFLINE')
    GROUP BY house_outage_id, system_status
)
SELECT 
    house_outage_id,
    system_status,
    outage_start,
    outage_end,
    duration_records,
    ROUND(EXTRACT('epoch' FROM (outage_end::timestamp - outage_start::timestamp)) / 60, 2) as duration_minutes
FROM outage_periods
ORDER BY outage_start DESC;

-- Room uptime statistics view
CREATE VIEW IF NOT EXISTS room_uptime_stats AS
WITH room_stats AS (
    SELECT 
        room_name,
        COUNT(*) as total_records,
        SUM(CASE WHEN room_power_on THEN 1 ELSE 0 END) as uptime_records,
        MIN(timestamp) as first_record,
        MAX(timestamp) as last_record
    FROM room_power_status
    GROUP BY room_name
)
SELECT 
    room_name,
    total_records,
    uptime_records,
    first_record,
    last_record,
    ROUND((uptime_records * 100.0 / total_records), 2) as uptime_percentage,
    ROUND(EXTRACT('epoch' FROM (last_record::timestamp - first_record::timestamp)) / 3600, 2) as total_hours_monitored
FROM room_stats;

-- System reliability view
CREATE VIEW IF NOT EXISTS system_reliability AS
WITH system_stats AS (
    SELECT 
        COUNT(*) as total_records,
        SUM(CASE WHEN system_status = 'ONLINE' THEN 1 ELSE 0 END) as online_records,
        SUM(CASE WHEN system_status = 'BACKUP' THEN 1 ELSE 0 END) as backup_records,
        SUM(CASE WHEN system_status = 'CRITICAL' THEN 1 ELSE 0 END) as critical_records,
        SUM(CASE WHEN system_status = 'OFFLINE' THEN 1 ELSE 0 END) as offline_records,
        MIN(timestamp) as monitoring_start,
        MAX(timestamp) as monitoring_end
    FROM power_status
)
SELECT 
    total_records,
    online_records,
    backup_records,
    critical_records,
    offline_records,
    monitoring_start,
    monitoring_end,
    ROUND((online_records * 100.0 / total_records), 2) as online_percentage,
    ROUND((backup_records * 100.0 / total_records), 2) as backup_percentage,
    ROUND((critical_records * 100.0 / total_records), 2) as critical_percentage,
    ROUND((offline_records * 100.0 / total_records), 2) as offline_percentage,
    ROUND(EXTRACT('epoch' FROM (monitoring_end::timestamp - monitoring_start::timestamp)) / 3600, 2) as total_hours_monitored
FROM system_stats;