# SSH Troubleshooting Guide for Claw-Clan

Diagnosing and fixing SSH connectivity issues between claw-clan peers.

---

## Common SSH Errors

### "Permission denied (publickey)"

**Full error:**
```
<user>@<ip>: Permission denied (publickey).
```

**Cause:** The remote machine does not have this machine's public key in its `~/.ssh/authorized_keys` file.

**Fixes:**

1. **Copy the key to the remote machine:**
   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<remote-ip>
   ```

2. **If ssh-copy-id fails** (because you cannot SSH in at all), you need physical or out-of-band access to the remote machine. On the remote machine, manually add the public key:
   ```bash
   # On the LOCAL machine, display the public key
   cat ~/.ssh/id_ed25519.pub

   # On the REMOTE machine, append it to authorized_keys
   echo "<paste-public-key-here>" >> ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   ```

3. **Wrong key type:** If the remote machine only accepts specific key types, check its `/etc/ssh/sshd_config` for `PubkeyAcceptedAlgorithms`. ed25519 is accepted by all modern macOS and Linux versions. If using an older system that only has RSA keys, see the Key Generation section below.

4. **Key exists but wrong permissions:**
   ```bash
   # On the REMOTE machine, fix permissions
   chmod 700 ~/.ssh
   chmod 600 ~/.ssh/authorized_keys
   ```

---

### "Host key verification failed"

**Full error:**
```
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
...
Host key verification failed.
```

**Cause:** The remote machine's host key has changed since the last connection. This happens when:
- The remote OS was reinstalled
- The remote machine's SSH keys were regenerated
- A different machine is now using the same IP address (DHCP reassignment)

**Fix:**

Remove the old host key entry for that IP:

```bash
ssh-keygen -R <remote-ip>
```

Then try connecting again. SSH will prompt to accept the new host key.

**Note:** claw-clan scripts use `-o StrictHostKeyChecking=accept-new` which auto-accepts host keys for first-time connections but still fails if a key has *changed*. The manual `ssh-keygen -R` step is required when a key changes.

---

### "Connection timed out"

**Full error:**
```
ssh: connect to host <ip> port 22: Connection timed out
```

**Cause:** The remote machine is unreachable at that IP address on port 22. Possible reasons:

1. **Wrong IP address.** The peer's IP may have changed (DHCP lease expired). Re-run discovery:
   ```bash
   ~/.openclaw/claw-clan/scripts/claw-discover.sh
   ```

2. **Firewall blocking port 22.** On the remote machine, check the macOS firewall:
   - System Settings > Network > Firewall
   - If the firewall is on, ensure "Remote Login" (sshd) is allowed through

3. **Machine is off or sleeping.** macOS laptops sleep when the lid is closed. Wake the machine and try again. For always-on machines (Mac Studio, Mac Mini), check power and network connectivity.

4. **Different network segment.** Both machines must be on the same LAN. mDNS and SSH will not work across different subnets/VLANs without additional routing.

**Diagnostic steps:**

```bash
# Check if the IP is reachable at all
ping -c 3 <remote-ip>

# Check if port 22 is open
nc -z -w 5 <remote-ip> 22 && echo "Port 22 open" || echo "Port 22 closed/filtered"
```

---

### "Connection refused"

**Full error:**
```
ssh: connect to host <ip> port 22: Connection refused
```

**Cause:** The remote machine is reachable but SSH is not running on port 22.

**Fix:** On the remote macOS machine, enable Remote Login:

1. Open **System Settings** (or System Preferences on older macOS)
2. Navigate to **General > Sharing**
3. Enable **Remote Login**
4. Ensure the user account is listed under "Allow access for"

Alternatively, enable via command line on the remote machine:

```bash
sudo systemsetup -setremotelogin on
```

Verify SSH is running:

```bash
sudo launchctl list | grep ssh
```

Should show `com.openssh.sshd` in the output.

---

## SSH Key Generation

### Recommended: ed25519

ed25519 keys are smaller, faster, and more secure than RSA. All modern macOS versions support them.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
```

- `-t ed25519` -- key type
- `-f ~/.ssh/id_ed25519` -- output file path
- `-N ""` -- empty passphrase (required for unattended cron-based SSH)

**Important:** claw-clan uses `BatchMode=yes` in all SSH operations, which means no interactive passphrase prompts. Keys **must** have an empty passphrase, or the passphrase must be loaded into ssh-agent before cron runs.

### Fallback: RSA

If connecting to older systems that do not support ed25519:

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
```

When using RSA, update the `ssh-copy-id` command to reference the RSA key:

```bash
ssh-copy-id -i ~/.ssh/id_rsa.pub <user>@<remote-ip>
```

### Checking which keys exist

```bash
ls -la ~/.ssh/id_*
```

Typical output for ed25519:
```
-rw-------  1 user  staff   411 Jan 15 10:00 /Users/user/.ssh/id_ed25519
-rw-r--r--  1 user  staff    97 Jan 15 10:00 /Users/user/.ssh/id_ed25519.pub
```

---

## Copying Keys to Remote Machines

### Using ssh-copy-id (preferred)

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<remote-ip>
```

This appends the public key to the remote machine's `~/.ssh/authorized_keys`. You will be prompted for the remote user's password once.

### Manual method (when ssh-copy-id is unavailable or password auth is disabled)

1. Display the local public key:
   ```bash
   cat ~/.ssh/id_ed25519.pub
   ```

2. On the remote machine (via physical access, screen sharing, or another out-of-band method):
   ```bash
   mkdir -p ~/.ssh
   chmod 700 ~/.ssh
   echo "<paste-the-public-key>" >> ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   ```

### Verify authorized_keys on the remote

```bash
ssh <user>@<remote-ip> "cat ~/.ssh/authorized_keys"
```

Each line should be a complete public key. Verify your key appears in the list.

---

## Verifying SSH Connectivity

### Quick test (what claw-clan uses internally)

```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new <user>@<ip> echo test
```

- `-o BatchMode=yes` -- never prompt for passwords or passphrases; fail immediately if keys are not accepted
- `-o ConnectTimeout=5` -- give up after 5 seconds
- `-o StrictHostKeyChecking=accept-new` -- auto-accept host keys for new hosts, but reject changed keys

If this prints `test`, SSH is working correctly. If it returns any error, key exchange is incomplete.

### Using the claw-clan script

```bash
# Test a specific peer
~/.openclaw/claw-clan/scripts/claw-setup-ssh.sh test <user> <ip>

# Test all peers
~/.openclaw/claw-clan/scripts/claw-setup-ssh.sh check
```

---

## Enabling Remote Login (SSH)

SSH must be enabled on every machine in the fleet. On macOS this is done through System Settings.

### GUI method

1. Open **System Settings**
2. Go to **General > Sharing**
3. Toggle **Remote Login** to ON
4. Under "Allow access for", select "All users" or add the specific user account

### Command-line method

```bash
# Enable
sudo systemsetup -setremotelogin on

# Verify
sudo systemsetup -getremotelogin
```

### Verify sshd is running

```bash
# Check if sshd is loaded
sudo launchctl list | grep ssh
# Should show: com.openssh.sshd

# Check if port 22 is listening
lsof -iTCP:22 -sTCP:LISTEN
```

### Linux

SSH is usually pre-installed on Linux. To ensure it's running:

```bash
sudo systemctl enable --now ssh    # Debian/Ubuntu
sudo systemctl enable --now sshd   # Fedora/RHEL
```

Verify:

```bash
systemctl is-active ssh || systemctl is-active sshd
```

If SSH is not installed:

```bash
sudo apt install openssh-server    # Debian/Ubuntu
sudo dnf install openssh-server    # Fedora/RHEL
```

---

## Bidirectional Key Exchange

claw-clan requires SSH to work **in both directions**. Machine A must be able to SSH into Machine B, AND Machine B must be able to SSH into Machine A.

This means:
- Machine A's public key must be in Machine B's `~/.ssh/authorized_keys`
- Machine B's public key must be in Machine A's `~/.ssh/authorized_keys`

### Step-by-step for two machines

**On Machine A:**
```bash
# Generate key if needed
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""

# Copy A's key to B
ssh-copy-id -i ~/.ssh/id_ed25519.pub <userB>@<ipB>
```

**On Machine B:**
```bash
# Generate key if needed
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""

# Copy B's key to A
ssh-copy-id -i ~/.ssh/id_ed25519.pub <userA>@<ipA>
```

**Verify from both sides:**
```bash
# From A
ssh -o BatchMode=yes <userB>@<ipB> echo "A->B OK"

# From B
ssh -o BatchMode=yes <userA>@<ipA> echo "B->A OK"
```

Both commands should succeed without any password prompts.

---

## SSH Agent Forwarding

SSH agent forwarding is **not needed** for claw-clan. All SSH connections are direct (machine-to-machine) using keys stored on disk. Agent forwarding is relevant when you need to use your SSH key on a remote machine to connect to a third machine (e.g., GitHub), but claw-clan does not chain SSH connections.

For reference, if you ever need agent forwarding for other purposes:

```bash
# Enable agent forwarding for a connection
ssh -A <user>@<ip>

# Or add to ~/.ssh/config for a specific host
Host <hostname>
  ForwardAgent yes
```

---

## Debugging with ssh -vvv

When SSH fails and the error message is not clear, use verbose mode to see the full connection negotiation:

```bash
ssh -vvv <user>@<ip>
```

This outputs detailed information about:
- Which key files SSH tries
- Authentication methods attempted and their results
- Host key verification details
- Network connection details

### What to look for in verbose output

**Key offered but not accepted:**
```
debug1: Offering public key: /Users/you/.ssh/id_ed25519 ED25519 SHA256:...
debug1: Authentications that can continue: publickey
```
If you see "Offering" but no "Server accepts key", the key is not in the remote's `authorized_keys`.

**No keys found:**
```
debug1: No more authentication methods to try.
```
No key files exist at the expected paths, or they are unreadable.

**Host key mismatch:**
```
debug1: Host key for <ip> has changed
```
The remote machine's identity has changed. Run `ssh-keygen -R <ip>` to clear the old entry.

**Connection-level failure:**
```
debug1: connect to address <ip> port 22: Connection refused
```
SSH is not running on the remote machine. Enable Remote Login.

### Saving verbose output to a file

```bash
ssh -vvv <user>@<ip> 2> ~/ssh-debug.log
```

The verbose output goes to stderr, so redirect with `2>` to capture it.
