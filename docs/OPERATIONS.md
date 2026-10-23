# NavaTunnel operations

[فارسی](OPERATIONS.fa.md) · [Home](../README.md) · [Tunnel guide](USAGE.md)

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

All displayed sizes and accepted limits use decimal GB (`10^9` bytes). The normal GRE counter records inner IPv4 traffic. Datacenter accounting can include encapsulation, retransmissions and other traffic. Dedicated peer-IP counters count all IPv4 traffic to/from that address, including unrelated services between those peers. Avoid overlapping counters.

The timer samples every 10 seconds. To repair a stopped/broken monitor while preserving saved totals and limits:

```bash
NavaTunnel traffic repair
systemctl status NavaTunnel-traffic.timer --no-pager
journalctl -u NavaTunnel-traffic.service -n 50 --no-pager
```

## Network and security settings

Main menu **2** contains these controls:

- **1:** network tuning, BBR, TCP buffers and MTU.
- **2:** direct GRE or FOU carrier and automatic carrier selection.
- **3:** SYN rate limits for the service ports. These can limit new connection attempts; an overly low setting can affect users. This is not application-layer DPI protection or a guarantee against filtering.
- **4:** random ICMP cover traffic. It sends additional packets and consumes traffic; it does not hide the volume of a busy tunnel.
- **5:** watchdog, carrier switching and optional Telegram alerts. Configure the recipient/token yourself before enabling alerts.
- **6:** FRP encryption/compression/TLS settings and their current status.
- **7:** memory/swap maintenance.
- **8:** restore saved network tuning.

GRE and FOU encapsulate packets; they do not encrypt them. FRP 0.71 uses TLS by default, but encryption and certificate identity verification are different properties. Check the actual FRPC/FRPS configuration and use application TLS as appropriate. The service ports of your application are not automatically given an application certificate by this script. KCP/FEC recovery and cover traffic can increase billable traffic.

## Back up

Main menu **3 → 5**, or:

```bash
NavaTunnel backup now
NavaTunnel backup status
```

Encrypted files are saved under `/var/backups/navatunnel/`, named `navatunnel-backup-YYYYMMDD-HHMMSS.enc`. The encryption key is `/etc/gre-panel/backup.key`. Preserve both the archive and its original key; a newly generated key cannot decrypt an old backup. The default retains seven encrypted backups; `backup now --keep N` changes retention for that run.

Backups contain managed configuration, tokens, counters and service files, not your foreign application database/users or FRP executables. Keep application backups separately. FRP binaries are installed during restore.

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

Restore on an Iran replacement with a different, already configured public IP:

```bash
NavaTunnel backup restore /var/backups/navatunnel/BACKUP.enc --local-ip NEW_IRAN_IP
```

Restore keeps a private pre-restore copy, validates archive paths, installs FRP, restores managed files and repairs traffic monitoring. Saved manual tunnel stops are respected. Inspect errors if any service does not start; successful file extraction alone does not prove connectivity. Reapply each updated connection code on its matching foreign server after an Iran address change. If that foreign host has several Iran connections, select the existing connection in its menu or pass its `--foreign-id N --force` explicitly. Client connection addresses/DNS may also need updating.

## Migrate over SSH

Main menu **3 → 8** asks for the destination IPv4, SSH port/user, optional private-key **file path**, optional existing backup and destination public IP. Leave the key-path prompt empty to use SSH agent/password authentication; do not type a password into the path field. A first-login forced password change must be completed through a normal interactive SSH login first.

The destination needs root access, or a user with passwordless sudo, systemd and Internet access to download dependencies. The operation replaces destination settings after keeping a private copy. The source stays running.

```bash
NavaTunnel migrate --host DESTINATION_IP --local-ip DESTINATION_PUBLIC_IP
```

Optional arguments are `--port 2222`, `--user ubuntu`, `--identity /root/.ssh/id_ed25519` and `--backup /path/to/BACKUP.enc`.

On completion, the destination path for updated foreign commands is printed. Apply each command to its matching foreign server, test every tunnel and only then retire the source. Configuration migration does not automatically update client subscriptions/DNS or migrate your application database.

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

Ping the opposite **actual internal GRE IP** shown in the configuration. Do not assume it is `10.10.10.1`; later installations use allocated `10.200.*` addresses. Public-IP ping measures a different path from application traffic. Ping loss can also reflect ICMP filtering or rate limiting.

`203/EXEC` usually means the service executable is missing or cannot run. Repair FRP installation with `NavaTunnel download-cores`, inspect the service journal and restart the affected service. A TCP `connection refused` means the destination rejected that connection; check the matching FRPS listener/control port before changing tunnel protocols.

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
