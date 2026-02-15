-- 001-initial-schema.sql
-- Claw-clan PostgreSQL schema

CREATE TABLE IF NOT EXISTS fleet_instances (
  gateway_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  lead_number INTEGER NOT NULL,
  ip TEXT NOT NULL,
  ssh_user TEXT NOT NULL,
  version TEXT NOT NULL DEFAULT '1.0.0',
  registered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  github_repo TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS peer_status (
  gateway_id TEXT PRIMARY KEY REFERENCES fleet_instances(gateway_id),
  status TEXT NOT NULL DEFAULT 'unknown' CHECK (status IN ('online', 'offline', 'unresponsive', 'unknown')),
  last_seen TIMESTAMPTZ,
  last_ping_attempt TIMESTAMPTZ,
  missed_pings INTEGER NOT NULL DEFAULT 0,
  ssh_connectivity BOOLEAN NOT NULL DEFAULT false,
  claw_clan_installed BOOLEAN NOT NULL DEFAULT false,
  mdns_broadcasting BOOLEAN NOT NULL DEFAULT false,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS ping_history (
  id SERIAL PRIMARY KEY,
  source_gateway TEXT NOT NULL,
  target_gateway TEXT NOT NULL,
  success BOOLEAN NOT NULL,
  timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  response_ms INTEGER
);

CREATE INDEX IF NOT EXISTS idx_ping_history_target ON ping_history(target_gateway, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_ping_history_timestamp ON ping_history(timestamp DESC);

CREATE TABLE IF NOT EXISTS incident_log (
  id SERIAL PRIMARY KEY,
  gateway_id TEXT NOT NULL,
  event_type TEXT NOT NULL CHECK (event_type IN ('offline', 'online', 'recovery', 'reinstall', 'skill_sync', 'leader_change')),
  details JSONB,
  timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_incident_log_gateway ON incident_log(gateway_id, timestamp DESC);

CREATE TABLE IF NOT EXISTS skill_audit (
  id SERIAL PRIMARY KEY,
  gateway_id TEXT NOT NULL,
  skill_name TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('install', 'update', 'remove')),
  source TEXT,
  timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
