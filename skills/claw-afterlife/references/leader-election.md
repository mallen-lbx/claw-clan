# Leader Election Reference

## Overview

claw-clan uses a **static leader election** model based on lead numbers. Every instance in the fleet is assigned a unique integer lead number during setup. The instance with the **lowest lead number** among all currently online instances is the leader.

Leadership is not voted on or negotiated. It is deterministic: read the lead numbers, find the lowest among online peers, and compare to your own.

## Lead Number Assignment

Each instance receives a `leadNumber` (unique integer) stored in `~/.openclaw/claw-clan/state.json` during initial setup. Lead numbers must be unique across the fleet. Lower numbers have higher leadership priority.

Example state excerpt:

```json
{
  "gatewayId": "gw-abc123",
  "name": "Studio Mac",
  "leadNumber": 1,
  "sshUser": "mallen",
  "ip": "192.168.1.50"
}
```

Peer files in `~/.openclaw/claw-clan/peers/<gateway-id>.json` also contain each peer's `leadNumber`, along with their current `status` (`online`, `offline`, `unresponsive`, or `unknown`).

## Static Assignment vs Dynamic Election

claw-clan uses **static assignment**. The lead number is set once at setup and does not change. There is no consensus protocol, no heartbeat-based voting, and no quorum requirement. The algorithm is purely local: each instance independently evaluates the same data (peer files on disk) and arrives at the same conclusion about who the leader is.

This makes the system simple, predictable, and free from split-brain issues. The tradeoff is that lead numbers must be coordinated manually during setup to ensure uniqueness.

## How Leadership Is Determined

The rule is simple: **lowest lead number wins**, but only among instances that are currently online.

1. Read this instance's `leadNumber` from `state.json`.
2. Iterate over all peer files in `~/.openclaw/claw-clan/peers/`.
3. For each peer with `status == "online"`, compare its `leadNumber`.
4. If no online peer has a lower lead number than this instance, this instance is the leader.

### Acting Leader (Failover)

When the current leader goes offline (detected via missed pings), the next-lowest lead number among remaining online instances automatically becomes the acting leader. No explicit handoff occurs. Each instance simply re-evaluates leadership whenever it checks.

For example, with three instances (lead numbers 1, 2, 3):
- All online: instance 1 is leader.
- Instance 1 goes offline: instance 2 becomes leader.
- Instance 1 and 2 go offline: instance 3 becomes leader.

### Leadership Reclamation

When a lower-numbered instance comes back online, it automatically reclaims leadership. The lowest lead number always wins. The previously acting leader does not need to yield explicitly; it simply re-evaluates and discovers it is no longer the lowest.

Continuing the example above:
- Instance 1 recovers: instance 1 immediately becomes leader again.
- Instance 2 and 3 detect this on their next check and stop performing leader duties.

## Edge Cases

### All Peers Offline

If every peer in `~/.openclaw/claw-clan/peers/` has a status other than `"online"`, this instance is the leader by default. There is no one to compare against, and the fleet needs a leader to handle monitoring and recovery.

### Tie-Breaking

Lead numbers must be unique integers. A tie should never occur. If it did (due to a setup error), the first-registered instance would win by virtue of being encountered first during the peer file iteration. However, the correct response to discovering duplicate lead numbers is to fix the configuration, not to rely on iteration order.

### Single Instance Fleet

If there are no peer files (the fleet has only one instance), that instance is always the leader. The loop over peers finds nothing, so the instance's own lead number remains the lowest by default.

## Leader Responsibilities

The leader is the only instance that should perform active fleet management tasks:

- **Monitoring**: Starting continuous monitoring cron jobs for offline peers (`claw-monitor.sh <gateway-id>`).
- **Recovery notifications**: Presenting recovery reports to the user when a peer comes back online.
- **Skill sync coordination**: Triggering `claw-sync-skills.sh` to push shared skills to recovered peers.
- **Reinstallation**: Driving the reinstallation procedure (SCP scripts, restart mDNS registration, reinstall cron) on recovered peers.

## Non-Leader Behavior

Non-leader instances still participate in the fleet:

- They run `claw-ping.sh` via cron to ping all peers and update peer status files.
- They update their own peer status data so others can see they are alive.
- They broadcast via mDNS so they can be discovered.

Non-leaders do **not**:
- Start monitoring cron jobs for offline peers.
- Initiate recovery actions or reinstallation procedures.
- Trigger skill syncs after recovery.

If a non-leader detects a peer is offline, it updates the peer file but does not act on it. Only the leader takes recovery actions.

## Checking Leadership

Use the following bash snippet to determine if the current instance is the leader. This is the same logic used in `SKILL.md` and can be embedded in any script or evaluated in a conversation.

```bash
MY_LEAD=$(jq -r '.leadNumber' ~/.openclaw/claw-clan/state.json)
LOWEST_LEAD=$MY_LEAD

for f in ~/.openclaw/claw-clan/peers/*.json; do
  [[ -f "$f" ]] || continue
  peer_status=$(jq -r '.status' "$f")
  peer_lead=$(jq -r '.leadNumber' "$f")
  # Only consider online peers
  if [[ "$peer_status" == "online" && "$peer_lead" -lt "$LOWEST_LEAD" ]]; then
    LOWEST_LEAD=$peer_lead
  fi
done

if [[ "$MY_LEAD" -le "$LOWEST_LEAD" ]]; then
  echo "This instance IS the leader (lead=$MY_LEAD)"
  IS_LEADER=true
else
  echo "This instance is NOT the leader (lead=$MY_LEAD, leader=$LOWEST_LEAD)"
  IS_LEADER=false
fi
```

Key details in this logic:
- `-le` (less than or equal) is used because when `LOWEST_LEAD` is still equal to `MY_LEAD`, no online peer has a lower number, meaning this instance wins.
- Peers with status `"offline"`, `"unresponsive"`, or `"unknown"` are excluded from consideration.
- The check should be performed before any leader-only action (starting monitoring, handling recovery, etc.).
