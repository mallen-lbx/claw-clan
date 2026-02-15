# Claw-Clan First-Time Setup Guide

Complete walkthrough for initializing a new claw-clan instance and joining a fleet.

---

## Prerequisites

Before starting, verify the following:

**Operating System:** macOS (darwin). claw-clan uses macOS-specific tools including `ipconfig`, `dns-sd`, and `launchctl`. Linux is not supported as a primary host (but Linux peers can interoperate via avahi -- see `mdns-reference.md`).

**Required binaries:**

```bash
# Verify all three are available
command -v ssh      || echo "MISSING: ssh (should be built-in on macOS)"
command -v ssh-keygen || echo "MISSING: ssh-keygen (should be built-in on macOS)"
command -v jq       || echo "MISSING: jq (install via: brew install jq)"
```

If `jq` is missing, install it:

```bash
brew install jq
```

**Network:** The machine must be connected to a LAN (Wi-Fi or Ethernet). mDNS discovery only works on the local network segment -- it does not cross routers or VLANs.

**SSH:** Remote Login must be enabled in System Settings > General > Sharing > Remote Login. This allows other machines to SSH into this one.

---

## Step 1: Collect Configuration (Interactive Prompts)

Setup is interactive. The skill collects five values from the user before writing any files.

### 1.1 Gateway ID

- **Prompt:** "What gateway ID should this machine use?"
- **Default:** `$(hostname)` -- the machine's hostname (e.g., `Marks-Mac-Studio`)
- **Rules:** Must be unique across the fleet. Used as the primary identifier in peer files and mDNS TXT records. No spaces allowed; hyphens and alphanumerics only.

### 1.2 Friendly Name

- **Prompt:** "What friendly name should this instance have?"
- **Default:** None -- this is required.
- **Rules:** Human-readable label for display and logs. Can contain spaces. Examples: `Studio`, `MacBook Air`, `Office Mac`. Used as the mDNS service name and in log output.

### 1.3 Lead Number

- **Prompt:** "What lead number should this instance have? (1 = highest priority)"
- **Default:** None -- must be provided as an integer.
- **Rules:** Must be a positive integer. Must be unique across the fleet. Lower numbers have higher priority for leader election in claw-afterlife. If peers already exist, check their lead numbers first to avoid conflicts:

```bash
# Show lead numbers already in use
for f in ~/.openclaw/claw-clan/peers/*.json; do
  jq -r '[.name, .leadNumber] | @tsv' "$f" 2>/dev/null
done
```

### 1.4 SSH User

- **Prompt:** "What SSH username should peers use to connect to this machine?"
- **Default:** `$(whoami)` -- the current logged-in user.
- **Rules:** Must be a valid user account on this machine with SSH access enabled.

### 1.5 GitHub Repo URL (Optional)

- **Prompt:** "What is the GitHub repo URL for shared skills? (optional, press Enter to skip)"
- **Default:** None -- can be left empty and configured later.
- **Rules:** SSH format preferred (e.g., `git@github.com:user/repo.git`). HTTPS works too. Used by `claw-sync-skills.sh` to push/pull shared skills across the fleet. If skipped, skill sync will not be available until configured.

---

## Step 2: Create Directory Structure

Create the claw-clan data directory and subdirectories:

```bash
mkdir -p ~/.openclaw/claw-clan/{peers,logs}
```

This creates:

| Path | Purpose |
|------|---------|
| `~/.openclaw/claw-clan/` | Root data directory |
| `~/.openclaw/claw-clan/peers/` | Per-peer JSON status files |
| `~/.openclaw/claw-clan/logs/` | Log files (ping, monitor, mDNS, events) |

---

## Step 3: Create state.json

The state file holds this machine's identity. Write it using `jq`:

```bash
jq -n \
  --arg gid "<gateway-id>" \
  --arg name "<friendly-name>" \
  --argjson lead <lead-number> \
  --arg ip "$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)" \
  --arg user "<ssh-user>" \
  --arg repo "<github-repo-or-null>" \
  '{
    gatewayId: $gid,
    name: $name,
    leadNumber: $lead,
    ip: $ip,
    sshUser: $user,
    version: "1.0.0",
    registeredAt: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
    githubRepo: $repo
  }' > ~/.openclaw/claw-clan/state.json
```

Replace the `<placeholder>` values with the user's answers from Step 1. If no GitHub repo was provided, pass `"null"` as the `--arg repo` value.

**Verify the file was written correctly:**

```bash
cat ~/.openclaw/claw-clan/state.json | jq .
```

Expected output should show all fields populated with the collected values, plus the current IP address, version `1.0.0`, and a `registeredAt` timestamp.

---

## Step 4: Create config.json

The config file holds operational settings with sensible defaults:

```bash
jq -n '{
  backend: "json",
  pingIntervalMinutes: 15,
  offlineThresholdPings: 2,
  monitorIntervalMinutes: 5,
  postgres: {
    host: null,
    port: 5432,
    database: "claw_clan",
    user: null,
    password: null,
    deployed: false,
    deployMethod: null
  }
}' > ~/.openclaw/claw-clan/config.json
```

| Setting | Default | Meaning |
|---------|---------|---------|
| `backend` | `"json"` | Storage backend. `"json"` uses local files; `"postgres"` uses a database. |
| `pingIntervalMinutes` | `15` | How often the cron job pings peers. |
| `offlineThresholdPings` | `2` | How many missed pings before a peer is marked `offline`. |
| `monitorIntervalMinutes` | `5` | How often `claw-monitor.sh` checks a specific peer (leader-only). |
| `postgres` | all null | PostgreSQL connection settings. Only relevant if `backend` is changed to `"postgres"`. |

---

## Step 5: Register on mDNS

Register this instance on the LAN via Bonjour/mDNS so other claw-clan instances can discover it:

```bash
~/.openclaw/claw-clan/scripts/claw-register.sh start
```

**What this does:**

1. Generates a LaunchAgent plist at `~/Library/LaunchAgents/com.openclaw.claw-clan-mdns.plist`
2. The plist runs `/usr/bin/dns-sd -R` with the instance's name, gateway ID, lead number, and version as TXT records
3. `KeepAlive` is set to `true` -- if the `dns-sd` process dies, launchd restarts it automatically
4. `RunAtLoad` is `true` -- the service starts at login
5. Loads the agent via `launchctl bootstrap gui/<uid>`

The service type registered is `_openclaw._tcp` on the `local` domain, port 22.

**Verify it is running:**

```bash
launchctl print gui/$(id -u)/com.openclaw.claw-clan-mdns
```

If this shows process details and a PID, the registration is active.

---

## Step 6: Discover Peers

Browse the LAN for other claw-clan instances:

```bash
~/.openclaw/claw-clan/scripts/claw-discover.sh
```

The script browses for `_openclaw._tcp` services for 5 seconds (configurable via first argument), resolves each one, extracts TXT records (gateway, name, lead), resolves hostnames to IPs, and saves peer files to `~/.openclaw/claw-clan/peers/<gateway-id>.json`.

**If no peers are found:** This is expected when setting up the first machine in a fleet. The peer directory will be empty until other machines register.

**If peers are found:** Each discovered peer gets a JSON file in the peers directory. Review them:

```bash
for f in ~/.openclaw/claw-clan/peers/*.json; do
  jq '{gatewayId, name, ip, leadNumber}' "$f"
done
```

---

## Step 7: Verify SSH Connectivity

Test SSH access to all discovered peers:

```bash
~/.openclaw/claw-clan/scripts/claw-setup-ssh.sh check
```

**What this does:**

1. Ensures a local SSH key exists (`~/.ssh/id_ed25519`). Generates one if missing.
2. For each peer in `~/.openclaw/claw-clan/peers/`, attempts `ssh -o BatchMode=yes <user>@<ip> echo 'claw-clan-handshake'`
3. On success: updates the peer file with `sshConnectivity: true`
4. On failure: prints step-by-step instructions for exchanging SSH keys (see `ssh-troubleshooting.md`)

**SSH is bidirectional.** Both machines need each other's public keys in `~/.ssh/authorized_keys`. If SSH fails, follow the printed instructions on both machines.

---

## Step 8: Install Keep-Alive Cron

Install a cron job that pings all peers on a regular interval:

```bash
(crontab -l 2>/dev/null | grep -v 'claw-ping.sh'; echo "*/15 * * * * ${HOME}/.openclaw/claw-clan/scripts/claw-ping.sh >> ${HOME}/.openclaw/claw-clan/logs/ping.log 2>&1 # claw-clan") | crontab -
```

**What this does:**

1. Reads the existing crontab
2. Removes any old `claw-ping.sh` entries (prevents duplicates)
3. Adds a new entry that runs `claw-ping.sh` every 15 minutes
4. Output is appended to `~/.openclaw/claw-clan/logs/ping.log`
5. The `# claw-clan` comment at the end is used as a tag for identification

The ping script SSHes into each peer and checks for the `claw-clan-ack` response. It updates each peer's `status`, `lastSeen`, `missedPings`, and `sshConnectivity` fields. After `offlineThresholdPings` consecutive missed pings (default: 2), a peer is marked `offline`.

---

## Step 9: Verification Checklist

After completing all steps, verify everything is working:

### 9.1 Check state.json exists and is valid

```bash
jq . ~/.openclaw/claw-clan/state.json
```

Should output this machine's gateway ID, name, lead number, IP, SSH user, version, and registration timestamp.

### 9.2 Check config.json exists and is valid

```bash
jq . ~/.openclaw/claw-clan/config.json
```

Should output backend, ping interval, offline threshold, monitor interval, and postgres settings.

### 9.3 Check LaunchAgent is running

```bash
launchctl print gui/$(id -u)/com.openclaw.claw-clan-mdns 2>&1 | head -5
```

Should show the service label and a PID. If it says "Could not find service", the LaunchAgent is not loaded. Re-run `claw-register.sh start`.

### 9.4 Check mDNS is broadcasting

```bash
# Browse for 3 seconds -- this machine's name should appear
timeout 3 dns-sd -B _openclaw._tcp local 2>/dev/null || true
```

The output should include a line with this machine's friendly name.

### 9.5 Check cron is installed

```bash
crontab -l 2>/dev/null | grep 'claw-clan'
```

Should show the `claw-ping.sh` cron entry. If empty, re-run the cron installation command from Step 8.

### 9.6 Check peer files (if peers exist)

```bash
ls -la ~/.openclaw/claw-clan/peers/
for f in ~/.openclaw/claw-clan/peers/*.json; do
  jq -r '[.name, .gatewayId, .status, .sshConnectivity] | @tsv' "$f"
done | column -t
```

Should list all discovered peers with their status and SSH connectivity.

### 9.7 Check log directory

```bash
ls -la ~/.openclaw/claw-clan/logs/
```

Should contain `mdns-register.log` (from the LaunchAgent) and `ping.log` (after the first cron run).

---

## Adding to an Existing Fleet

When joining a fleet that already has claw-clan instances running:

### Before Setup

1. **Get lead numbers in use.** Ask the fleet or check a peer's machine:
   ```bash
   # On an existing fleet member
   for f in ~/.openclaw/claw-clan/peers/*.json; do
     jq -r '[.name, .leadNumber] | @tsv' "$f"
   done
   jq -r '[.name, .leadNumber] | @tsv' ~/.openclaw/claw-clan/state.json
   ```
   Choose a lead number not already in use.

2. **Get gateway IDs in use.** Same approach -- ensure the new machine's gateway ID is unique.

### During Setup

Follow Steps 1--8 as normal, using a unique gateway ID and lead number.

### After Setup

1. **Run discovery on the new machine** to find existing peers:
   ```bash
   ~/.openclaw/claw-clan/scripts/claw-discover.sh
   ```

2. **Run discovery on each existing peer** so they find the new machine. SSH into each peer and run:
   ```bash
   ssh <user>@<peer-ip> "~/.openclaw/claw-clan/scripts/claw-discover.sh"
   ```
   Or wait for the next ping cycle -- peers will eventually discover the new machine via mDNS browse during keep-alive.

3. **Exchange SSH keys bidirectionally** between the new machine and every existing peer. For each peer:

   On the new machine:
   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub <peer-user>@<peer-ip>
   ```

   On each existing peer:
   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub <new-user>@<new-ip>
   ```

4. **Verify connectivity** from the new machine:
   ```bash
   ~/.openclaw/claw-clan/scripts/claw-setup-ssh.sh check
   ```

5. **Wait for the first ping cycle** (up to 15 minutes) or trigger a manual ping:
   ```bash
   ~/.openclaw/claw-clan/scripts/claw-ping.sh
   ```

After this, the new machine is a full member of the fleet. It will appear in every peer's status output and participate in keep-alive monitoring.
