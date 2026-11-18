CREATE TABLE IF NOT EXISTS devices (
    install_id TEXT PRIMARY KEY,
    install_secret_hash TEXT,
    first_seen TEXT NOT NULL,
    last_seen TEXT NOT NULL,
    launch_count INTEGER NOT NULL DEFAULT 1,
    manufacturer TEXT,
    model TEXT,
    system_type TEXT,
    os_caption TEXT,
    os_version TEXT,
    os_build TEXT,
    os_architecture TEXT,
    cpu_name TEXT,
    cpu_cores INTEGER,
    cpu_threads INTEGER,
    ram_gb REAL,
    device_json TEXT NOT NULL,
    launcher_version TEXT,
    last_received_ms INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_devices_manufacturer ON devices(manufacturer);
CREATE INDEX IF NOT EXISTS idx_devices_model ON devices(model);
CREATE INDEX IF NOT EXISTS idx_devices_os ON devices(os_caption, os_build);
