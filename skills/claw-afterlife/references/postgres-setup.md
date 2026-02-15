# PostgreSQL Setup Reference

## When to Use PostgreSQL

claw-clan defaults to a JSON file backend (peer files in `~/.openclaw/claw-clan/peers/`, fleet data in `fleet.json`). This works well for small fleets and simple monitoring.

Switch to PostgreSQL when you need:
- **Historical data**: Ping history, incident logs, and skill audit trails are stored in dedicated tables. The JSON backend only keeps current state.
- **Audit trails**: The `incident_log` and `skill_audit` tables provide a full timeline of events.
- **Queryable status**: Run SQL queries against fleet data, filter by time ranges, aggregate ping success rates, and generate reports.

## Switching at Any Time

You can switch from JSON to PostgreSQL at any point. The migration is additive, not destructive:
- JSON peer files continue to exist as a local fallback (the Postgres storage backend writes to both).
- The `config.json` `backend` field controls which storage backend is active.
- Existing peer state is preserved in the JSON files; new data flows into Postgres once switched.

To switch back to JSON, update the `backend` field in `config.json` (see the end of this document).

---

## Option A: Existing PostgreSQL

If you already have a PostgreSQL server running, connect claw-clan to it.

### 1. Update config.json

```bash
jq '.backend = "postgres" | .postgres.host = "<host>" | .postgres.port = <port> | .postgres.database = "<db>" | .postgres.user = "<user>" | .postgres.password = "<pass>"' \
  ~/.openclaw/claw-clan/config.json > /tmp/config.json && mv /tmp/config.json ~/.openclaw/claw-clan/config.json
```

Replace `<host>`, `<port>`, `<db>`, `<user>`, and `<pass>` with your actual connection details.

### 2. Run Migrations

```bash
psql -h <host> -p <port> -U <user> -d <db> -f ~/.openclaw/claw-clan/migrations/001-initial-schema.sql
```

You will be prompted for the password. This creates the five tables if they do not already exist (all statements use `CREATE TABLE IF NOT EXISTS`).

### 3. Test Connection

```bash
PGPASSWORD="<pass>" psql -h <host> -p <port> -U <user> -d <db> -c "SELECT count(*) FROM fleet_instances;"
```

A successful response (even if the count is 0) confirms the connection and schema are working.

---

## Option B: Docker Deployment

Deploy a new PostgreSQL instance via Docker. This is the simplest path if you do not have an existing server.

### 1. Run the Container

```bash
CLAW_PG_PASS=$(openssl rand -base64 32)

docker run -d \
  --name claw-clan-postgres \
  --restart unless-stopped \
  -e POSTGRES_DB=claw_clan \
  -e POSTGRES_USER=claw \
  -e POSTGRES_PASSWORD="${CLAW_PG_PASS}" \
  -p 5432:5432 \
  -v claw-clan-pgdata:/var/lib/postgresql/data \
  postgres:17-alpine
```

Key details:
- **Image**: `postgres:17-alpine` (lightweight, production-ready).
- **Volume**: `claw-clan-pgdata` is a named Docker volume for persistent storage. Data survives container restarts and removal.
- **Restart policy**: `unless-stopped` ensures the container restarts automatically after reboots.
- **Password**: Auto-generated via `openssl rand -base64 32`. Store it securely.

### 2. Display Connection Info

```bash
echo "=== claw-clan PostgreSQL Connection Info ==="
echo "Host:     $(hostname -I 2>/dev/null | awk '{print $1}' || ipconfig getifaddr en0)"
echo "Port:     5432"
echo "Database: claw_clan"
echo "User:     claw"
echo "Password: ${CLAW_PG_PASS}"
echo "=============================================="
echo ""
echo "Save this information. You will need it for config distribution."
```

Present this to the user and advise them to save it.

### 3. Run Migrations

Wait a few seconds for Postgres to initialize, then:

```bash
PGPASSWORD="${CLAW_PG_PASS}" psql -h localhost -p 5432 -U claw -d claw_clan \
  -f ~/.openclaw/claw-clan/migrations/001-initial-schema.sql
```

### 4. Update config.json

```bash
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || ipconfig getifaddr en0)

jq --arg host "$HOST_IP" --arg pass "$CLAW_PG_PASS" \
  '.backend = "postgres" | .postgres.host = $host | .postgres.port = 5432 | .postgres.database = "claw_clan" | .postgres.user = "claw" | .postgres.password = $pass' \
  ~/.openclaw/claw-clan/config.json > /tmp/config.json && mv /tmp/config.json ~/.openclaw/claw-clan/config.json
```

---

## Option C: Portainer Deployment

If you manage Docker through Portainer, deploy PostgreSQL as a Portainer stack.

### 1. Detect Portainer Endpoint

```bash
PORTAINER_URL="http://localhost:9000"
PORTAINER_TOKEN="<your-api-token>"

# Get the first endpoint ID
ENDPOINT_ID=$(curl -s -H "X-API-Key: ${PORTAINER_TOKEN}" \
  "${PORTAINER_URL}/api/endpoints" | jq '.[0].Id')
```

### 2. Create the Stack

The stack uses a `docker-compose.yml` format submitted via the Portainer API:

```bash
CLAW_PG_PASS=$(openssl rand -base64 32)

curl -s -X POST \
  -H "X-API-Key: ${PORTAINER_TOKEN}" \
  -H "Content-Type: application/json" \
  "${PORTAINER_URL}/api/stacks/create/standalone/string?endpointId=${ENDPOINT_ID}" \
  -d "$(jq -n \
    --arg name "claw-clan-postgres" \
    --arg compose "
version: '3.8'
services:
  postgres:
    image: postgres:17-alpine
    container_name: claw-clan-postgres
    restart: unless-stopped
    ports:
      - '5432:5432'
    environment:
      POSTGRES_DB: claw_clan
      POSTGRES_USER: claw
      POSTGRES_PASSWORD: '${CLAW_PG_PASS}'
    volumes:
      - claw-clan-pgdata:/var/lib/postgresql/data

volumes:
  claw-clan-pgdata:
    driver: local
" \
    '{Name: $name, StackFileContent: $compose}')"
```

### 3. Verify the Stack

```bash
curl -s -H "X-API-Key: ${PORTAINER_TOKEN}" \
  "${PORTAINER_URL}/api/stacks" | jq '.[] | select(.Name == "claw-clan-postgres")'
```

Then run migrations and update `config.json` as described in Option B.

---

## Post-Deployment Steps

After deploying PostgreSQL (via any option), complete these steps:

### 1. Display Connection Info to User

Present the full connection details (host, port, database, user, password) and advise the user to save them securely. This information is needed if the database is ever reconfigured or if another tool needs access.

### 2. Distribute Config to All Online Agents

Push the updated `config.json` to every online peer so they also use the Postgres backend:

```bash
MY_USER=$(jq -r '.sshUser' ~/.openclaw/claw-clan/state.json)

for peer_file in ~/.openclaw/claw-clan/peers/*.json; do
  [[ -f "$peer_file" ]] || continue
  peer_status=$(jq -r '.status' "$peer_file")
  [[ "$peer_status" == "online" ]] || continue

  peer_ip=$(jq -r '.ip' "$peer_file")
  peer_user=$(jq -r '.sshUser // "'"$MY_USER"'"' "$peer_file")
  peer_name=$(jq -r '.name // "unknown"' "$peer_file")

  echo "Distributing config to ${peer_name} (${peer_ip})..."
  scp ~/.openclaw/claw-clan/config.json "${peer_user}@${peer_ip}:~/.openclaw/claw-clan/config.json"
done
```

### 3. Save to claw-afterlife State

Store the Postgres connection details in the claw-afterlife state so that recovery procedures can restore the database configuration on peers that come back online:

```bash
# The connection info is already in config.json.
# Ensure config.json is included in the SCP during reinstallation.
# claw-monitor.sh copies scripts/; config.json at the claw-clan root
# should also be pushed during recovery.
```

### 4. Environment Variables

The Postgres connection can also be configured via environment variables, which take precedence over `config.json` when set:

| Variable | Description | Example |
|---|---|---|
| `CLAW_PG_HOST` | PostgreSQL host address | `192.168.1.50` |
| `CLAW_PG_PORT` | PostgreSQL port | `5432` |
| `CLAW_PG_DB` | Database name | `claw_clan` |
| `CLAW_PG_USER` | Database user | `claw` |
| `CLAW_PG_PASS` | Database password | `(generated value)` |

These are useful for Docker deployments, CI/CD pipelines, or environments where you do not want passwords in `config.json`.

---

## Schema Overview

The migration `001-initial-schema.sql` creates five tables:

### fleet_instances

Stores the identity and configuration of every instance in the fleet.

| Column | Type | Description |
|---|---|---|
| `gateway_id` | TEXT (PK) | Unique gateway identifier |
| `name` | TEXT | Human-readable instance name |
| `lead_number` | INTEGER | Leadership priority (lower = higher priority) |
| `ip` | TEXT | LAN IP address |
| `ssh_user` | TEXT | SSH username for remote access |
| `version` | TEXT | claw-clan version |
| `registered_at` | TIMESTAMPTZ | When this instance was first registered |
| `github_repo` | TEXT | Shared skills GitHub repository URL |
| `updated_at` | TIMESTAMPTZ | Last update timestamp |

### peer_status

Tracks the current status of each peer as observed by this instance.

| Column | Type | Description |
|---|---|---|
| `gateway_id` | TEXT (PK, FK) | References `fleet_instances` |
| `status` | TEXT | `online`, `offline`, `unresponsive`, or `unknown` |
| `last_seen` | TIMESTAMPTZ | Last successful contact |
| `last_ping_attempt` | TIMESTAMPTZ | Last ping attempt (successful or not) |
| `missed_pings` | INTEGER | Consecutive failed pings |
| `ssh_connectivity` | BOOLEAN | Whether SSH is currently reachable |
| `claw_clan_installed` | BOOLEAN | Whether claw-clan is installed on the peer |
| `mdns_broadcasting` | BOOLEAN | Whether the peer is broadcasting via mDNS |
| `updated_at` | TIMESTAMPTZ | Last update timestamp |

### ping_history

Append-only log of every ping attempt. Indexed by target gateway and timestamp for efficient querying.

| Column | Type | Description |
|---|---|---|
| `id` | SERIAL (PK) | Auto-incrementing ID |
| `source_gateway` | TEXT | Gateway that sent the ping |
| `target_gateway` | TEXT | Gateway that was pinged |
| `success` | BOOLEAN | Whether the ping succeeded |
| `timestamp` | TIMESTAMPTZ | When the ping occurred |
| `response_ms` | INTEGER | Response time in milliseconds (if successful) |

### incident_log

Records significant fleet events. The `event_type` is constrained to: `offline`, `online`, `recovery`, `reinstall`, `skill_sync`, `leader_change`.

| Column | Type | Description |
|---|---|---|
| `id` | SERIAL (PK) | Auto-incrementing ID |
| `gateway_id` | TEXT | The gateway involved |
| `event_type` | TEXT | Type of event |
| `details` | JSONB | Arbitrary JSON payload with event details |
| `timestamp` | TIMESTAMPTZ | When the event occurred |

### skill_audit

Tracks skill installations, updates, and removals. The `action` is constrained to: `install`, `update`, `remove`.

| Column | Type | Description |
|---|---|---|
| `id` | SERIAL (PK) | Auto-incrementing ID |
| `gateway_id` | TEXT | The gateway where the action occurred |
| `skill_name` | TEXT | Name of the skill |
| `action` | TEXT | What happened (`install`, `update`, `remove`) |
| `source` | TEXT | Where the skill came from (e.g., GitHub URL) |
| `timestamp` | TIMESTAMPTZ | When the action occurred |

---

## Backup Recommendations

### Automated Backups via pg_dump

Schedule a daily backup using cron:

```bash
# Add to crontab on the machine running PostgreSQL
(crontab -l 2>/dev/null; echo "0 3 * * * PGPASSWORD='<pass>' pg_dump -h localhost -p 5432 -U claw claw_clan | gzip > ~/.openclaw/claw-clan/backups/claw_clan_\$(date +\%Y\%m\%d).sql.gz 2>&1 # claw-clan-backup") | crontab -
```

This runs at 3:00 AM daily and writes compressed backups to `~/.openclaw/claw-clan/backups/`.

### Manual Backup

```bash
mkdir -p ~/.openclaw/claw-clan/backups
PGPASSWORD="<pass>" pg_dump -h localhost -p 5432 -U claw claw_clan \
  | gzip > ~/.openclaw/claw-clan/backups/claw_clan_$(date +%Y%m%d_%H%M%S).sql.gz
```

### Restore from Backup

```bash
gunzip -c ~/.openclaw/claw-clan/backups/claw_clan_20250510.sql.gz \
  | PGPASSWORD="<pass>" psql -h localhost -p 5432 -U claw -d claw_clan
```

### Backup Retention

Consider removing backups older than 30 days:

```bash
find ~/.openclaw/claw-clan/backups -name "claw_clan_*.sql.gz" -mtime +30 -delete
```

---

## Switching Back to JSON

To revert to the JSON file backend:

```bash
jq '.backend = "json"' ~/.openclaw/claw-clan/config.json > /tmp/config.json \
  && mv /tmp/config.json ~/.openclaw/claw-clan/config.json
```

The Postgres database remains intact and can be reconnected at any time by changing the backend field back to `"postgres"`. No data is lost in either direction. The JSON peer files are always maintained as a local fallback regardless of the active backend.

After switching, distribute the updated `config.json` to all online peers:

```bash
for peer_file in ~/.openclaw/claw-clan/peers/*.json; do
  [[ -f "$peer_file" ]] || continue
  peer_status=$(jq -r '.status' "$peer_file")
  [[ "$peer_status" == "online" ]] || continue
  peer_ip=$(jq -r '.ip' "$peer_file")
  peer_user=$(jq -r '.sshUser' "$peer_file")
  scp ~/.openclaw/claw-clan/config.json "${peer_user}@${peer_ip}:~/.openclaw/claw-clan/config.json"
done
```
