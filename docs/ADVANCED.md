# Optional NavaTunnel networking features

These features are independent of the web panel and do not use Backhaul or a
paid activation service. The repository remains under its existing AGPL-3.0
license. None of the new engines, cluster routing or tuning switches is enabled
by updating the script.

Update with `NavaTunnel update-all`, reopen `NavaTunnel`, then choose **2)
Advanced settings for speed and security**:

- **9) NavaLink:** FRP over a reverse SSH carrier.
- **10) Cluster:** SSH-managed Iran peers, health debounce and owned NAT rules.
- **11) Network tools:** path-MTU measurement, coordinated tcpMux settings and
  pool diagnostics.

## NavaLink

NavaLink creates this path:

```text
Users -> Iran frps public ports -> reverse SSH carrier -> foreign frpc -> local inbounds
```

Iran opens the SSH connection to the foreign server. FRP remains the relay;
GRE is not used by this engine. TCP and UDP proxies are supported; UDP is
carried through the SSH TCP stream. SSH and FRP TLS encrypt the carrier, but
this does not guarantee immunity to DPI, removal of loss, or higher throughput.
TCP head-of-line blocking and SSH CPU cost can make this engine slower on some
paths. Test it before replacing a working connection.

### Convert one existing Iran tunnel

On Iran:

```bash
NavaTunnel peer-list
NavaTunnel navalink setup --replace-peer 1
```

Replace `1` with the actual selected peer ID. The foreign IP, Iran IP, service
ports and name default to that peer's existing values. An alternate SSH port
can be supplied with `--ssh-port 2222`.

The operation authenticates to the foreign host as root using the normal SSH
agent/key/password flow. It verifies the host key, installs matching NavaTunnel
scripts and dependencies there, configures a dedicated restricted SSH account,
and establishes the carrier. Passwords are not saved. The foreign server needs
a supported Linux/systemd installation, working root SSH access and access to
dependency/core downloads.

The selected legacy FRP/GRE units and configs are privately saved under
`/etc/gre-panel/navalink/ID/previous`. Other peer units are not stopped. Existing
port mappings and per-proxy options on the converted foreign client are
retained. The converted peer moves out of the legacy GRE list and is managed
from the NavaLink menu instead. Its previous numerical ID and inner GRE
addresses are reserved for rollback.

### Create a separate connection

```bash
NavaTunnel navalink setup --host 198.51.100.20 --public-ip 203.0.113.10 --ports 2443,8443 --name test-link
```

Existing public listeners are not overwritten. For an existing GRE connection
to the same peer, use explicit conversion instead: independent interface and
peer-IP traffic counters are not allowed to double-charge the same path.
Only one independently accounted NavaLink connection per peer IP is supported.

### Manage or revert

The setup prints a connection ID. Use it in these commands, separately on each
end where appropriate:

```bash
NavaTunnel navalink status
NavaTunnel navalink logs --id ID
NavaTunnel navalink stop --id ID
NavaTunnel navalink start --id ID
NavaTunnel navalink restart --id ID
NavaTunnel navalink endpoint --id ID --host NEW_PEER_IP
NavaTunnel navalink remove --id ID
```

`remove` removes the local NavaLink connection and restores its saved GRE
configuration if it was converted. Run removal on both ends to revert the
whole connection. Incomplete provisioning is reported rather than treated as
success; remote rollback is attempted, and the error includes the ID needed
for manual cleanup if SSH recovery is unavailable.

The carrier uses a dedicated `navaID` account, not an unrestricted root key.
Its key cannot run commands, allocate a TTY, open local forwards or bind a
reverse listener other than its assigned loopback control port. The account
uses `AllowTcpForwarding remote` and `PermitOpen none` in a validated SSH Match
block. Host keys stay verified. Do not manually delete these Match blocks
while their carrier accounts remain authorized.

### Accounting and migration

A converted counter retains its totals, quota, blocked state and accounting
mode. In NavaLink mode it counts **all IPv4 wire traffic to/from that peer IP**,
including SSH overhead and any unrelated traffic between those same two
servers. It is not the previous inner-GRE measurement. A separate connection
gets a new counter, visible through the normal traffic menu.

New encrypted backups include these configs, carrier keys, private host-key
records, stopped-state markers and rollback snapshots. SSH migration prepares
Iran-side carriers on the destination, then hands over the owned source
carriers only after restore succeeds; the reverse listener cannot be owned by
two carriers at once. A failed handover attempts to stop the destination
carrier and restart the source. A brief interruption is expected. On the
foreign side, update its peer IP using `navalink endpoint` after moving Iran
so foreign-side wire accounting follows the new source IP. Opposite server
addresses, client connection addresses and DNS still need the usual migration
updates. Usage generated after the backup snapshot is not automatically
merged from the old host.

## SSH cluster

This is a group of Iran ingress servers. Each member must already have a
working route to the intended foreign services, the same public service ports,
and compatible user/inbound settings. It does not create those services or
synchronize VPN user databases.

On the Iran ingress that should control routing:

```bash
NavaTunnel cluster init --ports 2443,8443 --mode failover --failures 3 --recoveries 3
NavaTunnel cluster trust --host 203.0.113.20 --ssh-port 22
NavaTunnel cluster add --host 203.0.113.20 --ssh-port 22 --weight 1
NavaTunnel cluster status
NavaTunnel cluster enable
```

Trust asks for normal root SSH authentication once and installs a key that
can only report the peer's native cluster health. It cannot execute arbitrary
commands or open forwards. There is no web API or additional listening panel.
Configuration is disabled by default; enabling starts a 10-second systemd timer.
Three consecutive failing checks are required by default, with three healthy
checks for recovery.

Modes:

- `failover`: keep the local path while healthy; otherwise select the first
  healthy configured backup.
- `lowest-latency`: keep a healthy local path; choose the healthy backup with
  the lowest SSH health-query round-trip time when local fails. This is not a
  throughput or one-way latency benchmark.
- `weighted`: distribute **new connections** across the healthy local path and
  healthy peers in proportion to their weights.

Health requires an active relay and an established FRP control session. A
running process alone does not count, and ICMP loss alone does not trigger a
route change. All requested ports must be advertised by healthy local links
on a candidate. This is still not an end-to-end VPN authentication or download
test, and it does not currently offer a packet-loss percentage switch threshold.

Only NavaTunnel's dedicated NAT chain and marked forwarding/MASQUERADE rules
are changed. Existing conntrack entries and unrelated firewall chains are
preserved. The peer sees the forwarding Iran host's source IP. The original
client IP is not preserved through this NAT hop.

```bash
NavaTunnel cluster status
NavaTunnel cluster disable
NavaTunnel cluster remove --host 203.0.113.20
```

Disable returns new flows to the local path and removes the owned forwarding
rules. Existing TCP connections cannot be moved seamlessly to another server;
clients may need to reconnect. If the public ingress server itself becomes
unreachable, it cannot forward anything: DNS/client failover or an external
entry mechanism is still necessary. This is not automatic public-IP takeover.

## Network tools

```bash
# Read-only size probes, constrained by the current interface MTU:
NavaTunnel path-mtu --interface gre-tunnel --peer 10.200.0.1
# Explicitly save/apply the confirmed size through the existing MTU command:
NavaTunnel path-mtu --interface gre-tunnel --peer 10.200.0.1 --apply

NavaTunnel tcp-mux status
NavaTunnel tcp-mux off
NavaTunnel pool
```

MTU probes need meaningful ICMP responses and can be affected by filtering or
loss. No change is made when the baseline test fails. Applying an MTU still
requires the same value on the matching opposite tunnel; the existing KCP
minimum-size validation remains in force.

The tcpMux switch saves the setting for **legacy FRP configs on this host** and
future generated configs. Set the same value on both ends, then restart only
the intended tunnel when ready. Saving it does not automatically restart active
connections. NavaLink retains its own `tcpMux=false` configuration.

Pool diagnostics read recent messages and current limits. They do not silently
resize pools or restart frpc: `pool is full` is not by itself evidence that user
connections have failed.

## Restore safety and tests

Restore validates every archive member before any extraction, rejects path
traversal, links, devices, duplicates and unrelated destinations, and takes a
private pre-restore safety copy. Files are replaced atomically with private
permissions. An old backup containing unsupported custom paths is rejected
rather than extracted unrestrictedly.

Regression tests cover permissions, key restrictions, rollback, preserving
traffic quotas, health debounce, port/ID reservations, MTU and helper menus.
The namespace NAT lab checks actual forwarding and cleanup. The privileged
CI SSH lab checks actual FRP TCP/UDP over reverse SSH plus denied shell access,
local forwarding and a different reverse listener. These do not replace tests
on your own provider's network.
