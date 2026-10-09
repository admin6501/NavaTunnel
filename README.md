# NavaTunnel

**English** | [فارسی](README.fa.md)

FRP reverse tunnel management over GRE, developed and maintained by **admin6501**.
This NavaTunnel version includes Persian menus, per-tunnel traffic controls, protocol selection, persistent MTU settings, Iran IP migration, documentation, and bug fixes.
Management runs through SSH and a Persian terminal menu. The web panel, web server, panel installer, and Go build steps have been removed.

GRE can run directly or use FOU over UDP. FRP transport, encryption, and compression are applied on the foreign client; the Iran menu stores each tunnel's selection and passes it through a connection bundle. A web relay carrier for GRE is not available in this version.

There is no fixed limit on the number of foreign servers. Each tunnel needs a separate foreign IP and internal addresses, plus available control and service ports. Currently, each foreign server manages one FRPC connection.

## Installation and updates

Run as root on a Linux server with systemd, Python 3, and iptables:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/admin6501/NavaTunnel/main/install.sh)
```

Run `NavaTunnel` to open the menu or `NavaTunnel --help` for CLI help. For a local copy, run `sudo bash NavaTunnel.sh`. Tunnel setup installs required dependencies and binaries. Traffic and cover-traffic helpers are also Bash scripts. The script's interface and help remain in Persian; this document provides English instructions.

Use **Updates and maintenance → Full update**, or run:

```bash
NavaTunnel update-all
```

Close and reopen the menu afterward. Update Iran and each foreign server separately. Existing tunnels do not need to be deleted or recreated to use the new menus.

## Menu workflow

Run `NavaTunnel` to open the main menu:

1. **Create and manage tunnels → Create on Iran**: enter a name, both public IPs, and service ports. The token and internal addresses are generated automatically. Enter a control port manually, or press Enter / type `auto` to select an available port. Follow the same steps to add more foreign servers.
2. **Select and manage a tunnel**: select a tunnel from the numbered list, then change its name, ports, or foreign IP. Enter leaves an edit unchanged; option 0 goes back.
3. **Foreign connection code**: get the selected tunnel's bundle and run it on its foreign server, or paste it into the foreign connection menu. After changing service ports, apply the new bundle on the foreign side. The menu asks before replacing an existing connection.
4. **Traffic usage, limits, and reset**: select a tunnel and choose download, upload, or both. In the menu, `100` means 100GB; `0` means unlimited.

Menu entry, back navigation, and refresh clear the terminal screen so only the current page is visible. Action results and connection codes remain visible until Enter is pressed. Iran IP migration is available only in the shared tunnel menu.

Restart and delete actions on a tunnel's management page affect only that tunnel. An older single-tunnel Iran installation is imported automatically when its IP and GRE settings can be read from the service file. On a foreign server, use a new bundle to replace connection settings and the status menu to inspect the connection.

## Foreign server status and management

Under **Create and manage tunnels → 4) Tunnel list and status**, Iran tunnels are read from the peer registry and the foreign connection from `frpc.toml`. A foreign connection appears even without a peer registry. Its summary shows the internal Iran endpoint, FRP protocol, service status, GRE interface, and TCP/UDP ports. Tokens are not printed in the list. An active local service alone does not prove the remote endpoint is reachable.

On a foreign server, **3) Select and manage a tunnel** opens FRPC management: status, restart this connection, traffic settings, reconfiguration using a bundle, and persistent MTU. If both roles are configured on a server, choose Iran or foreign first. Recreating a tunnel is not required for it to appear in the foreign list.

## Selecting an FRP protocol

On **Iran**, open **Create and manage tunnels → Select and manage a tunnel → 10) Select FRP protocol**. Choose TCP, KCP, QUIC, WebSocket, or WSS. The saved selection is shown above the menu; Enter keeps it. Then get a new bundle using option 5 and apply it on the foreign server.

On the **foreign server**, **Connect foreign server using a bundle** offers the same five protocols after you paste the bundle. Enter keeps the protocol encoded in the bundle. Manual foreign setup also offers protocol selection. Replacing an existing connection requires confirmation in the menu.

The **foreign FRP client** uses the selected transport; the Iran FRP server accepts the connection. Saving a selection on Iran does not change an already running foreign client. Direct GRE or FOU carrier selection remains separate, under tunnel management option 4.

| Protocol | Behavior |
|---|---|
| TCP | Default transport with TCP retransmission |
| KCP | UDP transport with FEC and additional traffic usage |
| QUIC | UDP transport without KCP's FEC mode |
| WebSocket | FRP connection over WebSocket |
| WSS | WebSocket connection with TLS |

KCP and loss recovery stay consistent: selecting KCP enables recovery; selecting another protocol disables it. Enabling recovery through option 9 selects KCP. Disabling it switches KCP to TCP; an already selected non-KCP protocol is preserved.

```bash
NavaTunnel peer-protocol --id 2 --protocol quic
NavaTunnel peer-token --id 2
```

Apply the new bundle using an updated NavaTunnel installation on the foreign server. Iran uses the control port over UDP for KCP and the next port for QUIC, or the preceding port if the control port is 65535. UFW rules allow these ports; configure any custom firewall separately. Protocol selection alone does not guarantee better speed or unrestricted connectivity.

## Per-tunnel packet-loss recovery

During tunnel creation, the menu asks whether to enable packet-loss recovery with a `[y/N]` prompt:

- `y` selects **KCP with FEC** for that tunnel's FRP connection.
- `n` or Enter keeps the default TCP transport without additional FEC. TCP still performs its usual retransmissions.

For an existing tunnel, open **Select and manage a tunnel → 9) Packet-loss recovery**. The submenu offers **1) Enable**, **2) Disable**, and **3) Show saved selection**. Enter or 0 returns without changing the setting.

The selection is stored independently in the tunnel's record, then read back and verified. Closing the menu or restarting the script does not clear it. After a change, a ready-to-run foreign setup command is printed. Apply the new bundle on the foreign server and confirm replacement when using the menu.

Iran displays the **saved Iran selection**, which does not verify the foreign client's current state. Changes made directly on the foreign server are not automatically synchronized back to Iran. Select the same protocol using Iran option 10 to keep future bundles consistent. FEC status follows the protocol: KCP enables it; other protocols do not use KCP FEC. Both sides need an updated NavaTunnel version to transfer these settings through the bundle.

```bash
NavaTunnel loss-recovery --id 2 --mode on
NavaTunnel peer-token --id 2
# Apply the new bundle on the foreign server:
NavaTunnel setup-foreign --bundle '<bundle>' --force
# Explicitly disable recovery on the foreign server:
NavaTunnel setup-foreign --bundle '<bundle>' --loss-recovery off --force
```

`add-peer` and `setup-foreign` also accept `--loss-recovery on|off`. Explicitly enabling recovery while explicitly choosing a non-KCP protocol, such as QUIC, is rejected. Older connection bundles remain supported.

FEC can reconstruct some lost data using redundant packets. It does not remove loss from the underlying route or other server traffic, and recovery is not guaranteed for severe or burst loss. FRP 0.71.0 uses 10 data shards and 3 parity shards for KCP: approximately 30% redundancy at the coded payload level for large streams, plus protocol headers and retransmissions. Actual usage depends on packet sizes and path conditions. This additional traffic counts toward tunnel and datacenter usage. KCP sends UDP inside GRE on the control port; custom firewalls must allow it.

## Persistent per-tunnel MTU

On Iran, use **Tunnel management → 11) Persistent MTU**. On the foreign server, use **Connection management → 5) Persistent MTU**. The current value is displayed; Enter cancels. Only the selected tunnel interface is changed, and the setting is saved in its service file and `/etc/gre-panel/mtu.json`.

Restarting, changing the carrier, and applying standard optimizations preserve the saved per-interface MTU. If applying a change fails, the previous setting is restored. MSS rules use the path MTU and the selected tunnel interface.

Set compatible MTUs on both ends; changing Iran alone does not change the foreign interface. The default is 1380 and accepted values range from 576 to 1476. Your path may require a smaller value; reducing MTU does not always improve speed. The current KCP implementation sends 1350-byte packets, requiring at least 1378 bytes inside GRE with IPv4/UDP headers. The script rejects selecting KCP with a smaller MTU or lowering an active KCP tunnel below that minimum.

Example for the second Iran tunnel and its corresponding foreign connection, using TCP:

```bash
# Iran server:
NavaTunnel mtu --interface gre-t2 --value 1300
# Corresponding foreign server:
NavaTunnel mtu --interface gre-tunnel --value 1300
```

## Per-tunnel traffic usage

Each tunnel's management page shows download, upload, their total, and usage charged against the configured limit. Use **option 7 on Iran** or **option 3 on the foreign server** to manage that connection's traffic without selecting it again or entering a counter ID. Refresh, limit, accounting direction, reset, and unlimited settings are available there. Reset requires confirmation.

**Main menu option 6** lists all counters, discovers existing tunnels, and registers an interface or dedicated peer IP. Usage is displayed in multiline GB cards for narrow terminals. In menus, `100` means 100GB and `0` means unlimited. Menus and CLI accept only GB; a number without a suffix also means GB. One GB equals 1,000,000,000 bytes. GiB and other size units are rejected. Existing limits remain stored in bytes; only their displayed unit changes to GB.

New tunnels are registered automatically using their interface names, such as `gre-tunnel` or `gre-t2`. If a counter is missing, the menu asks before registering it, and counting starts at that moment. If a refresh fails, the last saved usage is shown with a warning. Historical datacenter usage cannot be recovered by the counter.

```bash
NavaTunnel traffic discover
NavaTunnel traffic list
NavaTunnel traffic limit gre-tunnel 100GB --mode both
NavaTunnel traffic status gre-tunnel
NavaTunnel traffic reset gre-tunnel
NavaTunnel traffic mode gre-tunnel download
NavaTunnel traffic limit gre-tunnel 0  # Unlimited; remove quota blocking
```

Register an interface or dedicated peer IP:

```bash
NavaTunnel traffic add tunnel-a --interface tun0 --limit 100GB --mode upload
NavaTunnel traffic add frp-a --peer 203.0.113.10 --limit 500GB --mode both
NavaTunnel traffic remove tunnel-a  # Remove the counter and its blocking rules
```

- **download**: bytes received by this server (RX).
- **upload**: bytes sent by this server (TX).
- **both**: the sum of both directions.
- Interface counters measure IPv4 traffic inside the tunnel, including IP headers and keepalive traffic. Peer-IP counters include all IPv4 traffic to/from that peer, including overhead and other connections, so use a dedicated IP. Duplicate or overlapping targets are rejected.
- Counters are sampled every 10 seconds. Reaching the limit in the selected accounting direction blocks both directions of that tunnel using dedicated iptables rules. Other tunnels retain independent counters and limits.
- Reset starts a new accounting period and removes quota blocking. Changing direction recalculates usage from the same period's RX/TX totals. Raising or removing the limit unblocks the tunnel when usage is below the new limit.
- Usage and limits persist in `/etc/gre-panel/traffic.json`. `NavaTunnel-traffic.service` restores rules after boot, and its timer continues sampling. A reboot or firewall replacement can lose traffic since the previous sample; usage may exceed a limit by traffic sent during a sampling interval.
- These local limits do not match datacenter billing. IPv6 accounting is not supported, including IPv6 traffic inside custom TUN interfaces.

Inspect the counter service:

```bash
systemctl status NavaTunnel-traffic.timer NavaTunnel-traffic.service
journalctl -u NavaTunnel-traffic.service
```

## Configuration and backups

Logs are stored in `/var/log/navatunnel` and backups in `/var/backups/navatunnel`. Watchdog and DPI services use the `navatunnel-` prefix. When upgrading older installations, stop old services and transfer any required backups or logs before activating the new services. Old paths and services are not automatically migrated.

State remains in `/etc/gre-panel` for compatibility with existing installations; this directory name does not indicate an installed or running web panel. Encrypted backups use `/etc/gre-panel/backup.key`. Keep the original key when moving servers and store recovery material outside the server.

Traffic and MTU state are included in backups. After restoring onto a replacement server, run `NavaTunnel traffic list` to install and enable the counter service and timer. An already installed legacy web panel is not automatically removed during an upgrade; back it up and migrate before replacement. Full uninstall includes cleanup of the old panel's files and service.

Script updates come from this repository. FRP binaries are downloaded from release assets and fallback sources. Script messages, menus, errors, installer text, and CLI help are Persian. Command names, configuration keys, protocols, and raw output from external tools such as FRP and systemd retain their technical names and original language.

## Checks and tests

```bash
for script in *.sh; do bash -n "$script"; done
python3 -m unittest discover -s tests -v
```

Tests cover ID allocation without a fixed peer cap, bundle generation, isolated tunnel deletion, TOML editing, port conflicts, missing arguments, carrier commands, and installation/backup failures. Traffic tests simulate firewall counters and check both directions, reset, independent limits, persistence, and unblocking. Management tests cover tunnel selection, protocols and recovery, foreign status, MTU persistence and rollback, traffic isolation, Persian help, and Iran IP migration.

Live network and systemd testing requires a Linux server with network administration privileges; those capabilities were unavailable in the development environment.

## Changing the Iran public IP

After making the new address available on the same server, select **Create and manage tunnels → 6) Change Iran IP (all tunnels)**. This action does not change the network interface's IP address.

The new public address is recorded for all tunnels and their persistent GRE services. Ports, tokens, MTU, and traffic counters are preserved. Previous settings are backed up, and a failed application triggers restoration. On servers behind NAT, GRE uses the local route address while the new public IP is encoded in connection bundles.

To reconnect, run each printed connection command on its corresponding foreign server. Commands include `--force` to replace the existing connection. Tunnels remain disconnected until this step is completed. This operation changes the address of the same Iran server; moving to a new server also requires transferring configuration.

Direct CLI command on Iran:

```bash
NavaTunnel iran-ip --ip NEW_IRAN_IP
```

After using the direct command, retrieve each tunnel's new bundle from **Foreign connection code** and apply it on the corresponding foreign server with `--force`.

## License

NavaTunnel is distributed under AGPL-3.0. See [LICENSE](LICENSE) for the license text.

## Selecting and changing the FRP control port

During tunnel creation on Iran, enter a control port, or press Enter / type `auto` for automatic selection; `0` cancels creation. The TCP control port, the same UDP port for KCP, and the companion UDP port for QUIC are checked against other tunnels, service ports, and active system listeners. QUIC uses the next port; with control port 65535, it uses 65534.

For an existing tunnel, select **Tunnel management → 12) Change this tunnel's FRP control port**. Enter a new port or type `auto`; Enter and `0` cancel. Only that tunnel's FRPS configuration and service change. Service ports, token, GRE, MTU, and traffic counters are preserved. Failed changes restore the previous configuration.

The foreign connection remains disconnected until you apply its new bundle. A ready-to-run command with `--force` is displayed; run it on that tunnel's foreign server. Active UFW rules are updated for the new ports. Configure custom and datacenter firewalls separately.

```bash
NavaTunnel peer-control-port --id 2 --port 45000
# Or select automatically:
NavaTunnel peer-control-port --id 2 --port auto
```
