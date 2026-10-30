# NavaTunnel operations

[فارسی](OPERATIONS.fa.md) · [Home](../README.md) · [Tunnel guide](USAGE.md) · [Commands](CLI.md) · [FAQ](FAQ.md)

Run the commands below as root. Replace uppercase example values and `ID` before running them.

## Traffic and quotas

Use main menu **6**, or a selected tunnel's **9** on Iran. Choose which direction counts toward the quota: download, upload or both. Reaching a limit blocks that counter's traffic; resetting usage also removes the quota block. A zero limit means unlimited.

```bash
NavaTunnel traffic list
NavaTunnel traffic status ID
NavaTunnel traffic limit ID 100GB --mode download
NavaTunnel traffic mode ID both
NavaTunnel traffic reset ID
NavaTunnel traffic limit ID 0
```

All displayed sizes and accepted limits use decimal GB (`10^9` bytes). Bare `100` and `100GB` both mean 100 GB; `GiB`, `MB` and other units are not accepted. Download means bytes received by the server running this counter; upload means bytes it sends. Changing accounting mode uses the already accumulated totals; it does not start a new period. Reset clears usage but retains the limit and accounting mode. Counter IDs are shown by `traffic list` and are separate from Iran peer IDs and foreign connection IDs.

The normal GRE counter records inner IPv4 traffic. Datacenter accounting can include encapsulation, retransmissions and other traffic. Dedicated peer-IP counters count all IPv4 traffic to/from that address, including unrelated services between those peers. Avoid overlapping counters. The two endpoints count from different perspectives; do not add both endpoint totals to estimate one provider's bill.

The timer samples every 10 seconds. To repair a stopped/broken monitor while preserving saved totals and limits:

```bash
NavaTunnel traffic repair
systemctl status NavaTunnel-traffic.timer --no-pager
journalctl -u NavaTunnel-traffic.service -n 50 --no-pager
```

## Network and security settings

Main menu **2** contains these controls:

- **1:** network tuning, BBR, TCP buffers and MTU.
- **2:** direct GRE, FOU and cycling to the next carrier.
- **3:** SYN rate limits for the service ports. These can limit new connection attempts; an overly low setting can affect users. This is not application-layer DPI protection or a guarantee against filtering.
- **4:** random ICMP cover traffic. It sends additional packets and consumes traffic; it does not hide the volume of a busy tunnel.
- **5:** watchdog, backup schedules and optional Telegram alerts. Configure the recipient/token yourself before enabling alerts. Monitoring alone does not enable automatic restart; a fresh configuration has `auto_restart` off.
- **6:** FRP encryption/compression/TLS settings and their current status.
- **7:** memory/swap maintenance.
- **8:** restore saved network tuning.

GRE and FOU encapsulate packets; they do not encrypt them. FRP 0.71 uses TLS by default, but encryption and certificate identity verification are different properties. Check the actual FRPC/FRPS configuration and use application TLS as appropriate. The service ports of your application are not automatically given an application certificate by this script. KCP/FEC recovery and cover traffic can increase billable traffic.

These are host-level tools. Global carrier commands can affect all active GRE interfaces; prefer the selected tunnel's carrier control when changing one path. Cycling a carrier is not automatic selection among Iran servers and does not measure client-side packet loss.

### Customize cover traffic and SYN limits

On the host where you want cover traffic, menu **2 → 4 → 6** saves interval and payload ranges; **7** activates that custom profile. These pings continue even during user traffic. CLI equivalent:

```bash
NavaTunnel chaff configure --min-ms 400 --max-ms 2800 --min-bytes 64 --max-bytes 1200
NavaTunnel perf chaff custom
NavaTunnel chaff status
```

Disable with `NavaTunnel chaff off`. Intervals are milliseconds; payload sizes are bytes and must fit the tunnel MTU. Configuration applies to this host's managed cover traffic, not one selected tunnel.

On Iran, menu **2 → 3 → 4** changes the SYN rate and burst; **1** enables the rules. Example values, not a universal recommendation:

```bash
NavaTunnel dpi-shield configure --rate 60/sec --burst 120
NavaTunnel dpi-shield on
NavaTunnel dpi-shield status
```

Disable with `NavaTunnel dpi-shield off`. The limit is per source IP and service port for TCP SYN packets, not requests per minute or download bandwidth; users behind the same NAT can share a source IP. It does not generate cover traffic. FRP `perf enc`, `comp` and `tls` selections need `NavaTunnel perf apply`; that is a host-wide apply/restart operation, not a selected-connection edit. Coordinate settings on both endpoints.

### Firewall and provider requirements

| Traffic | Where it must work |
| --- | --- |
| SSH on your chosen port | Management/migration source to destination |
| Service TCP/UDP ports | Users to Iran; the application's corresponding local ports on foreign |
| Direct GRE, IP protocol **47** | Between both public server IPs; this is not TCP/UDP port 47 |
| FOU UDP port, commonly 443 or 55555 | Between both public server IPs when that carrier is selected |
| FRP control traffic | Foreign to the Iran GRE address; TCP for TCP/WS/WSS, UDP for KCP/QUIC |

Check both the operating-system firewall and the provider firewall. Restrict endpoint-to-endpoint access where practical. Do not disable the entire firewall to troubleshoot one port. Root on a container does not guarantee the kernel/network privileges needed for GRE/FOU.

## Back up

Main menu **3 → 5**, or:

```bash
NavaTunnel backup now
NavaTunnel backup status
```

Encrypted files are saved under `/var/backups/navatunnel/`, named `navatunnel-backup-YYYYMMDD-HHMMSS.enc`. The encryption key is `/etc/gre-panel/backup.key`. Preserve both the archive and its original key; a newly generated key cannot decrypt an old backup. The default retains seven encrypted backups; `backup now --keep N` changes retention for that run.

Backups contain managed configuration, tokens, counters and service files, not your foreign application database/users or FRP executables. Keep application backups separately. FRP binaries are installed during restore.

Automatic pre-change directories such as `TIMESTAMP_pre_setup_foreign`, `iran-ip-*` and `gre-addresses-*` are local safety copies, not the encrypted `.enc` files accepted by `backup restore`. An SSH-created fresh backup can be inside a `migration-*` subdirectory; use the exact printed path. `backup status` lists `.enc` files in the top-level backup directory only.

### Schedule backups

Use **3 → 7** to save an hourly or daily schedule. CLI alternatives (choose one):

```bash
NavaTunnel backup schedule --every 6
```

```bash
NavaTunnel backup schedule --daily 03:00
```

Scheduling saves the setting; ensure the maintenance timer is installed and active. `NavaTunnel watchdog on` enables it along with monitoring. Inspect `systemctl status navatunnel-watchdog.timer --no-pager` and `NavaTunnel watchdog status`. Daily schedules use the server's local time (`timedatectl`). `NavaTunnel backup schedule --off` disables the schedule. `watchdog off` disables monitoring alerts but leaves the maintenance timer available; it does not cancel a saved backup schedule. Copy backups off-host too.

## Restore

On a replacement server, install NavaTunnel first. Securely copy the backup and its original key there, preserving private file permissions. Place the original key at `/etc/gre-panel/backup.key` before restoring. Keep a copy of any destination key if you still need its earlier backups.

Validate an archive without applying it:

```bash
NavaTunnel backup restore /var/backups/navatunnel/BACKUP.enc --dry-run
```

Restore on the same IP:

```bash
NavaTunnel backup restore /var/backups/navatunnel/BACKUP.enc
```

Restore on an Iran **or foreign** replacement with a different, already configured public IP:

```bash
NavaTunnel backup restore /var/backups/navatunnel/BACKUP.enc --local-ip DESTINATION_PUBLIC_IP
```

`--local-ip` always means the **replacement server's own public IP**, regardless of its Iran/foreign role. It rebinds the restored local GRE endpoint and updates local registry addresses; remote endpoint IPs, tokens and quotas are preserved. Without this option, old local bindings remain. Manual restore through menu **3 → 6** does not ask for a new IP; use this CLI form when the replacement IP differs.

Restore keeps a private pre-restore copy, validates archive paths, installs FRP, restores managed files and repairs traffic monitoring. Saved manual tunnel stops are respected. Inspect errors if any service does not start; successful file extraction alone does not prove connectivity. Follow the role-specific steps below after an address change.

### Transfer a backup and key manually

On the source, replace `DESTINATION_IP` and the example backup filename:

```bash
ssh root@DESTINATION_IP 'install -d -m 700 /root/navatunnel-transfer'
scp /etc/gre-panel/backup.key /var/backups/navatunnel/BACKUP.enc root@DESTINATION_IP:/root/navatunnel-transfer/
```

Install NavaTunnel on the destination. Preserve its old key separately first if its old backups are needed. On the destination, install the source key and verify the copied archive:

```bash
install -d -m 700 /etc/gre-panel
install -m 600 /root/navatunnel-transfer/backup.key /etc/gre-panel/backup.key
chmod 600 /root/navatunnel-transfer/BACKUP.enc
NavaTunnel backup restore /root/navatunnel-transfer/BACKUP.enc --dry-run
```

Then restore that same path, replacing `DESTINATION_PUBLIC_IP` with the destination's own public IP:

```bash
NavaTunnel backup restore /root/navatunnel-transfer/BACKUP.enc --local-ip DESTINATION_PUBLIC_IP
```

For nonstandard SSH ports, `ssh` uses `-p PORT` and `scp` uses `-P PORT`.

## Migrate over SSH

Run main menu **3 → 8 on the old/source server**. This works for Iran and foreign sources, including a foreign host with several Iran connections. It copies the host's managed configuration, not just the tunnel currently selected in another menu.

| Prompt | What to enter |
| --- | --- |
| Destination IPv4 | The new server's SSH address |
| SSH port | Its SSH port; Enter uses 22 |
| SSH user | `root`, or a user with passwordless sudo |
| SSH private key path | An existing key **file path**, or Enter for agent/password authentication; never a password |
| Existing encrypted backup path | An existing source `.enc` path and its original key, or Enter to create a fresh backup |
| Destination tunnel public IPv4 | The **new server's own public IP**; Enter uses the SSH destination IP |

The last prompt means the new **foreign IP when moving foreign**, and the new **Iran IP when moving Iran**. It never asks for the opposite endpoint's address. A first-login forced password change must be completed through a normal interactive SSH login first, such as `ssh -t root@DESTINATION_IP`.

The destination needs root access, or a user with passwordless sudo, systemd and Internet access to download dependencies. The operation replaces destination settings after keeping a private copy. The source stays running.

```bash
NavaTunnel migrate --host DESTINATION_IP --local-ip DESTINATION_PUBLIC_IP
```

Optional arguments are `--port 2222`, `--user ubuntu`, `--identity /root/.ssh/id_ed25519` and `--backup /path/to/BACKUP.enc`.

### After moving Iran

1. On the destination Iran, verify **1 → 4** lists the restored tunnels and the saved Iran IP is the new one.
2. Migration prints a destination path like `/var/backups/navatunnel/migration-*-foreign-commands.txt`. It contains secret new connection commands. Alternatively obtain each through **1 → 3 → select → 8**.
3. On each matching foreign, select the existing Iran connection and use **9** to change its remote Iran IP, or **6** to apply its new code. CLI replacement must include the correct `--foreign-id N --force`, including if you use the generated file on a host with several connections.
4. Update client addresses/DNS if necessary, test each application and then retire the old Iran.

### After moving foreign

1. On the destination foreign, check `NavaTunnel foreign-list`; all restored Iran connections should be listed.
2. Move your application separately: Xray/V2Ray or panel, inbounds, users, database and required certificates. NavaTunnel's backup does not provide them.
3. On **every connected Iran**, select the matching tunnel through **1 → 3**, then **6: Change foreign server IP** and enter the new foreign IP. The Iran public IP itself is unchanged.
4. Test through each Iran. If restored settings need updating, use the selected connection on the new foreign; do not add a duplicate. Retire the old foreign only after all paths work.

Successful migration means installation/configuration restore completed; it cannot update opposite hosts, application databases or subscriptions automatically. The source is not stopped. Treat a pre-migration destination archive as a private safety copy, not an automatic rollback of all failed steps.

## Troubleshooting

Start with main menu **3 → 1** or `NavaTunnel status`. Logs are available through **3 → 3** and `NavaTunnel logs`.

```bash
systemctl status frps frpc --no-pager -l
journalctl -u frpc -n 50 --no-pager
```

On Iran with several tunnels, use the selected service name, such as `frps-2`, instead of assuming every tunnel uses `frps`. To inspect the first GRE interface:

```bash
ip -d tunnel show gre-tunnel
ip -4 addr show dev gre-tunnel
```

Use **3 → 1** or `NavaTunnel doctor check` for the peer-aware health check. `status` also shows service state, but its legacy first-interface ping is not a substitute for selecting the real peer. Ping the opposite **actual internal GRE IP** shown in the configuration. Do not assume `10.10.10.1` or `10.200.0.1`; new menu allocations can be elsewhere in `10.64.0.0/10`. Public-IP ping measures a different path from application traffic. Ping loss can also reflect ICMP filtering or rate limiting.

For a chosen interface, replace both placeholders:

```bash
ping -n -I GRE_INTERFACE -c 100 -i 0.2 -W 2 -w 30 PEER_GRE_IP
```

For a longer test that survives SSH disconnection:

```bash
nohup ping -n -I GRE_INTERFACE -c 1000 -i 0.2 -W 2 -w 240 PEER_GRE_IP > /tmp/navatunnel-ping.log 2>&1 < /dev/null &
```

Later read `tail -n 5 /tmp/navatunnel-ping.log`. To test a near-MTU packet, add `-M do -s PAYLOAD_BYTES`, where for IPv4 ICMP the payload must not exceed the inner MTU minus 28. Record whether the test ran during application load. RTT `mdev` describes RTT variation; it is not every application's definition of jitter. A successful idle ICMP test does not prove a loss-free loaded application path.

`203/EXEC` usually means the service executable is missing or cannot run. Repair FRP installation with `NavaTunnel download-cores`, inspect the service journal and restart the affected service. A TCP `connection refused` means the destination rejected that connection; check the matching FRPS listener/control port before changing tunnel protocols.

`work connection pool is full, discarding` alone does not prove that the process restarted or identify packet loss. Compare both endpoints' journals at the same time and check `systemctl show FRPC_SERVICE -p NRestarts -p ActiveEnterTimestamp` with the actual service name. `NRestarts=0` counts systemd restarts, not FRP reconnects within the same process. Do not blindly raise pool sizes or change protocol based on this message alone.

## Configuration locations and removal

| Path | Contents |
| --- | --- |
| `/etc/frp/frps*.toml` | Iran FRPS server settings and tokens |
| `/etc/frp/frpc*.toml` | Foreign FRPC settings and tokens |
| `/etc/gre-panel/peers.json` | Iran tunnel registry |
| `/etc/gre-panel/foreign.json` | Foreign connection registry |
| `/etc/gre-panel/traffic.json` | Saved usage, accounting modes and limits |
| `/etc/gre-panel/mtu.json`, `stopped/` | Persistent MTU values and manual stops |
| `/etc/gre-panel/perf.json`, `watchdog.json` | Host settings and optional alert credentials |
| `/etc/systemd/system/gre-t*.service` | Persistent GRE endpoint configuration |
| `/var/backups/navatunnel/` | Encrypted archives and private safety copies |

Keep registries/configuration private; do not post full tokens, connection codes, backup keys or Telegram credentials in tickets. Prefer the menus/CLI over hand-editing active state. The `gre-panel` directory name is retained for compatibility; it does not mean a web panel is installed.

To remove **one** tunnel, use its selected menu (**14** on Iran, **10** on foreign). Main menu **5** and `remove-tunnel` operate on all local tunnels; full `uninstall` also removes NavaTunnel and `/etc/gre-panel`, including the backup key. Copy a required encrypted backup **and its key off-host before uninstalling**. Removing one endpoint does not remove the opposite endpoint or your application.

## Upgrading from older versions

```bash
NavaTunnel update-all
NavaTunnel
```

Version 1.2.0 removes Cluster and NavaLink. Their menus, provisioning commands, daemon, APIs and routing code are no longer shipped. Ordinary GRE/FRP tunnels remain supported.

On startup, maintenance stops the removed owned services, removes only their firewall rules and privately archives their settings under `/var/backups/navatunnel/removed-features-*`. Earlier removed-tool settings can be archived under `removed-tools-*`. Unrelated firewall rules, root SSH keys and ordinary tunnel configuration are preserved.

A NavaLink connection converted from GRE is reverted to its saved GRE/FRP files, with counters/limits preserved and retargeted. Update **both endpoints** to complete that reversion; previously stopped services remain stopped. A standalone NavaLink connection has no saved GRE counterpart: it is stopped, its settings/usage are archived, and a new standard tunnel must be created if needed. Conflicting or incomplete rollback data produces an explicit error instead of overwriting an existing tunnel. Old backups are retired through the same process when restored.

The only remaining optional Go executable is the small TLS front used by FRP WSS. It has no Cluster daemon, SSH engine, web panel or management API. It is downloaded with checksum verification only when a WSS front is configured. An ordinary TCP installation does not need it.

## Backups and monitoring with several foreign connections

Backups include `foreign.json`, every FRPC/GRE configuration, per-connection carrier settings, counters and manual stops. Restore maps each client back to its own interface. After moving foreign to a new public IP, update the foreign address of the matching tunnel on **each Iran**.

The watchdog checks registered foreign connections separately. When automatic restart is enabled, recovery targets only the failed connection and respects manual stops. This is a coarse connectivity check, not a precise packet-loss measurement.
