# mDNS / Bonjour Technical Reference for Claw-Clan

How claw-clan uses multicast DNS for peer discovery on the local network.

---

## What is mDNS / Bonjour

mDNS (multicast DNS) is a protocol that resolves hostnames and discovers services on a local network without a central DNS server. Apple's implementation is called Bonjour. It operates over UDP port 5353 using multicast address 224.0.0.251 (IPv4) or ff02::fb (IPv6).

Key characteristics:
- **Link-local only:** Queries and responses stay on the local network segment. They do not cross routers or VLANs.
- **Zero configuration:** No DNS server, no manual IP entries. Machines announce themselves and discover each other automatically.
- **Built into macOS:** The `mDNSResponder` system daemon handles all mDNS operations. The `dns-sd` command-line tool provides a user interface to it.
- **Service discovery:** Beyond hostname resolution, mDNS supports advertising services (type, port, TXT metadata) so other machines can find them.

---

## Service Type

claw-clan registers and browses for:

```
_openclaw._tcp
```

This is the service type string used in all `dns-sd` commands. The format follows DNS-SD (DNS Service Discovery) conventions:
- `_openclaw` -- the service name (underscore prefix is required by the RFC)
- `._tcp` -- the transport protocol

The domain is always `local` for link-local mDNS.

The service advertises port **22** (SSH), since claw-clan communicates between peers via SSH.

---

## dns-sd Command Reference

The `dns-sd` command is the macOS CLI for interacting with mDNSResponder. All `dns-sd` commands run in the **foreground** and block until killed or timed out.

### -R: Register a Service

Advertise a service on the network. This is what `claw-register.sh` runs via LaunchAgent.

```bash
dns-sd -R "<service-name>" _openclaw._tcp local 22 \
  gateway=<gateway-id> \
  name=<friendly-name> \
  lead=<lead-number> \
  version=<version>
```

| Argument | Meaning |
|----------|---------|
| `-R` | Register mode |
| `"<service-name>"` | Human-readable name displayed during browse (the friendly name) |
| `_openclaw._tcp` | Service type |
| `local` | Domain (always `local` for mDNS) |
| `22` | Port number |
| `key=value ...` | TXT record key-value pairs (space-separated, each as a separate argument) |

**Behavior:**
- Runs in the foreground and blocks. The service is registered only while the process is alive.
- When the process exits, mDNS sends a "goodbye" packet (TTL=0) that tells other machines the service is gone.
- This is why a LaunchAgent with `KeepAlive: true` is required for persistent registration.

**Example from claw-register.sh:**

```bash
/usr/bin/dns-sd -R "Studio" _openclaw._tcp local 22 \
  gateway=Marks-Mac-Studio \
  name=Studio \
  lead=1 \
  version=1.0.0
```

### -B: Browse for Services

List all instances of a service type on the local network.

```bash
dns-sd -B _openclaw._tcp local
```

**Behavior:**
- Runs in the foreground and blocks indefinitely, printing new services as they appear.
- Use `timeout` to limit the browse duration:
  ```bash
  timeout 5 dns-sd -B _openclaw._tcp local
  ```
- Output format (one line per discovered service):
  ```
  Timestamp     A/R  Flags  if  Domain       Service Type        Instance Name
  14:30:22.123  Add  2      5   local.       _openclaw._tcp.     Studio
  14:30:22.456  Add  2      5   local.       _openclaw._tcp.     MacBook Air
  ```
- `Add` means a new service appeared. `Rmv` means a service disappeared (goodbye packet received).
- claw-discover.sh uses a 5-second timeout by default and parses the output for service names.

### -L: Lookup a Service

Resolve a specific service instance to get its hostname, port, and TXT records.

```bash
dns-sd -L "<service-name>" _openclaw._tcp local
```

**Behavior:**
- Runs in the foreground and blocks.
- Returns the hostname, port, and all TXT record key-value pairs.
- Output includes a line like:
  ```
  Studio._openclaw._tcp.local. can be reached at Marks-Mac-Studio.local.:22
    text record: gateway=Marks-Mac-Studio name=Studio lead=1 version=1.0.0
  ```
- Use `timeout` to prevent indefinite blocking:
  ```bash
  timeout 3 dns-sd -L "Studio" _openclaw._tcp local
  ```

### -G: Resolve Hostname to IP Address

Convert an mDNS hostname (e.g., `Marks-Mac-Studio.local.`) to an IP address.

```bash
dns-sd -G v4 Marks-Mac-Studio.local
```

| Argument | Meaning |
|----------|---------|
| `-G` | Get address mode |
| `v4` | IPv4 address (use `v6` for IPv6, `v4v6` for both) |
| hostname | The `.local` hostname to resolve |

**Behavior:**
- Runs in the foreground and blocks.
- Output includes the resolved IP:
  ```
  Marks-Mac-Studio.local. 192.168.1.50
  ```
- Use `timeout` to prevent indefinite blocking:
  ```bash
  timeout 3 dns-sd -G v4 Marks-Mac-Studio.local
  ```

### Chaining Browse -> Lookup -> Resolve

claw-discover.sh performs this full chain for each peer:

1. **Browse** (`-B`) for 5 seconds to get service instance names
2. **Lookup** (`-L`) each instance to get hostname, port, and TXT records
3. **Resolve** (`-G v4`) the hostname to an IP address
4. Save the results to a peer JSON file

---

## TXT Record Format

TXT records carry metadata about the service as key-value pairs. Each pair is a separate argument to `dns-sd -R`:

```bash
dns-sd -R "name" _openclaw._tcp local 22 \
  gateway=Marks-Mac-Studio \
  name=Studio \
  lead=1 \
  version=1.0.0
```

| Key | Value | Purpose |
|-----|-------|---------|
| `gateway` | Gateway ID string | Unique machine identifier, used as peer file name |
| `name` | Friendly name string | Human-readable label |
| `lead` | Integer | Leader election priority (lower = higher priority) |
| `version` | Semver string | claw-clan version for compatibility checking |

**Constraints:**
- Each TXT record key-value pair can be up to 255 bytes
- Total TXT record data should stay under 1300 bytes to avoid fragmentation
- Keys are case-insensitive by convention
- Values are UTF-8 strings

---

## LaunchAgent Lifecycle

Since `dns-sd -R` blocks in the foreground and the service disappears when the process exits, claw-clan uses a macOS LaunchAgent for persistence.

### Plist Location

```
~/Library/LaunchAgents/com.openclaw.claw-clan-mdns.plist
```

This is a per-user LaunchAgent (not system-wide). It runs under the current user's session.

### Key Plist Properties

| Key | Value | Effect |
|-----|-------|--------|
| `Label` | `com.openclaw.claw-clan-mdns` | Unique identifier for launchctl |
| `ProgramArguments` | `/usr/bin/dns-sd -R ...` | The command to run |
| `RunAtLoad` | `true` | Start automatically at login |
| `KeepAlive` | `true` | Restart the process if it exits for any reason |
| `StandardOutPath` | `~/.openclaw/claw-clan/logs/mdns-register.log` | stdout log |
| `StandardErrorPath` | `~/.openclaw/claw-clan/logs/mdns-register-err.log` | stderr log |

### KeepAlive Behavior

With `KeepAlive: true`, launchd monitors the process and restarts it immediately if it exits. This ensures:
- The mDNS registration survives crashes
- If the network drops and `dns-sd` exits, it restarts and re-registers
- The service is available as long as the user is logged in

### launchctl Commands (Modern macOS)

Modern macOS (Ventura and later) uses the `bootstrap`/`bootout` commands instead of the deprecated `load`/`unload`:

```bash
# Load (start) the LaunchAgent
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw.claw-clan-mdns.plist

# Unload (stop) the LaunchAgent
launchctl bootout gui/$(id -u)/com.openclaw.claw-clan-mdns

# Check status
launchctl print gui/$(id -u)/com.openclaw.claw-clan-mdns

# List all loaded services (filter for claw-clan)
launchctl list | grep claw-clan
```

**Note:** `gui/$(id -u)` is the launchd domain for the current user's GUI session. The `$(id -u)` evaluates to the numeric user ID (e.g., `501`).

### Service Disappearance on Process Death

When the `dns-sd -R` process exits:
1. mDNSResponder sends a "goodbye" multicast packet with TTL=0
2. Other machines on the network remove the service from their cache within seconds
3. Subsequent `-B` browses will no longer show this instance
4. If `KeepAlive` is `true`, launchd restarts the process and re-registers immediately

This is the correct behavior -- a dead process means the machine is unavailable, so the service should disappear from discovery.

---

## Firewall Considerations

### macOS Firewall and mDNS

mDNS is **exempt from the macOS firewall by default**. The `mDNSResponder` process is a system-level daemon with special privileges:

- It binds to UDP port 5353 regardless of firewall settings
- Bonjour discovery works even when the macOS firewall is enabled
- No firewall rules need to be added for mDNS to function

### SSH and Firewall

SSH (port 22) is **not** exempt from the firewall. If the macOS firewall is enabled:

1. Enabling "Remote Login" in System Settings automatically adds a firewall rule for `sshd`
2. If SSH connections are being blocked despite Remote Login being enabled, check:
   ```bash
   # List firewall rules (requires sudo)
   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --listapps
   ```
3. Manually allow SSH through the firewall:
   ```bash
   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/sbin/sshd
   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp /usr/sbin/sshd
   ```

---

## macOS Sequoia DNS Cache Workaround

On macOS Sequoia (15.x) and some later versions, mDNS discovery can become stale or fail after network changes (Wi-Fi reconnect, sleep/wake, VPN toggle). The system DNS cache and mDNSResponder may hold stale records.

**Workaround -- flush DNS cache and restart mDNSResponder:**

```bash
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```

- `dscacheutil -flushcache` clears the system DNS cache
- `killall -HUP mDNSResponder` sends SIGHUP to mDNSResponder, forcing it to re-read its configuration and re-probe the network

**When to use this:**
- Peers that were previously discoverable are no longer showing up in `dns-sd -B`
- A machine's IP changed (DHCP renewal) but mDNS still resolves to the old IP
- After waking from sleep, discovery seems broken
- After connecting/disconnecting from a VPN

**This does not affect LaunchAgent status.** The `dns-sd -R` process managed by the LaunchAgent continues running -- this just clears stale cache entries.

---

## Limitations

### Link-Local Only

mDNS multicast packets use a TTL of 255 and are scoped to the local network segment. They **do not cross:**

- Routers (even on the same physical network, different subnets will not see each other)
- VLANs (unless IGMP snooping and multicast routing are configured)
- VPN tunnels (unless the VPN explicitly bridges multicast traffic)
- NAT boundaries

**Implication for claw-clan:** All fleet members must be on the same LAN. If machines are on different subnets, mDNS discovery will not work and peers must be configured manually.

### Timing and Caching

- Services appear within 1-2 seconds of registration
- Goodbye packets propagate within 1-2 seconds of process exit
- macOS may cache results for up to 60 seconds (the mDNS record TTL)
- Browse operations may miss services that register/deregister during the browse window

### Name Conflicts

If two services register with the same instance name on the same service type, mDNS will automatically rename the second one by appending `(2)`, `(3)`, etc. Claw-friends uses the friendly name as the instance name, so ensure friendly names are unique across the fleet.

---

## Linux Compatibility

Linux does not include mDNSResponder but uses Avahi, which implements the same mDNS/DNS-SD protocols. A Linux machine can participate in a claw-clan fleet if Avahi is installed and configured.

### Installing Avahi

```bash
# Debian/Ubuntu
sudo apt install avahi-daemon avahi-utils

# Fedora/RHEL
sudo dnf install avahi avahi-tools

# Ensure the daemon is running
sudo systemctl enable avahi-daemon
sudo systemctl start avahi-daemon
```

### Equivalent Commands

| macOS (`dns-sd`) | Linux (`avahi`) | Purpose |
|------------------|-----------------|---------|
| `dns-sd -R "Name" _openclaw._tcp local 22 key=val` | `avahi-publish -s "Name" _openclaw._tcp 22 key=val` | Register |
| `dns-sd -B _openclaw._tcp local` | `avahi-browse _openclaw._tcp` | Browse |
| `dns-sd -L "Name" _openclaw._tcp local` | `avahi-browse _openclaw._tcp --resolve` | Lookup |
| `dns-sd -G v4 hostname.local` | `avahi-resolve -n hostname.local` | Resolve |

### Key Differences

- `avahi-publish` also blocks in the foreground like `dns-sd -R`. Use a systemd service for persistence (analogous to the macOS LaunchAgent).
- `avahi-browse` can be run with `--terminate` to exit after a specified period instead of using `timeout`.
- Avahi uses `/etc/avahi/avahi-daemon.conf` for configuration.
- The `.local` domain must not conflict with any unicast DNS -- Avahi handles this but some enterprise networks may cause issues.

### Linux LaunchAgent Equivalent (systemd)

For persistent registration on Linux, create a systemd user service:

```ini
# ~/.config/systemd/user/claw-clan-mdns.service
[Unit]
Description=claw-clan mDNS registration

[Service]
ExecStart=/usr/bin/avahi-publish -s "<name>" _openclaw._tcp 22 gateway=<gw> name=<name> lead=<num> version=1.0.0
Restart=always

[Install]
WantedBy=default.target
```

Enable and start:

```bash
systemctl --user enable claw-clan-mdns.service
systemctl --user start claw-clan-mdns.service
```
