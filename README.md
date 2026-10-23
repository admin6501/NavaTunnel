# NavaTunnel

[فارسی](README.fa.md) · [User guide](docs/USAGE.md) · [Backup and maintenance](docs/OPERATIONS.md)

Manage GRE tunnels and FRP reverse connections from an English terminal menu. Run the script on your Iran and foreign servers; application inbounds stay on the foreign server.

```text
Users → Iran service ports → FRP over GRE/FOU → Foreign application
```

## Install

Run as root on each server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/admin6501/NavaTunnel/main/install.sh)
```

Open the menu afterward:

```bash
NavaTunnel
```

Use a Linux server with systemd and root access. Ubuntu 22.04/24.04 and Debian with systemd are suitable. The installer needs Internet access to download dependencies and FRP binaries. The kernel/provider must allow the selected GRE or FOU carrier. Service ports and the carrier must also be allowed by your server and provider firewalls.

## Create your first tunnel

1. On **Iran**, select **1 → 1: Create tunnel on Iran**.
2. Enter a name, both public IPv4 addresses and the application ports already listening on the foreign server, such as `443,8443`.
3. Leave loss recovery off to start with TCP. Choose an unused FRP control port, or press Enter for automatic selection.
4. After creation, select **1 → 3**, choose the tunnel, then **8: Get foreign connection code**.
5. On the **matching foreign server**, install NavaTunnel and run only the command shown in the connection-code box.
6. Confirm the setup reports success and test your application through the Iran address.

The code contains a secret token. Keep it private. Creating a tunnel forwards existing applications; it does not create inbounds or application users.

## Menu

| Main option | Purpose |
| --- | --- |
| 1 | Create, select and manage tunnels; change Iran public IP |
| 2 | Network tuning, GRE/FOU, DPI SYN limits, cover traffic, watchdog and FRP settings |
| 3 | Health checks, logs, encrypted backups, restore and SSH migration |
| 4 | Update, download FRP binaries and inspect system settings |
| 5 | Uninstall |
| 6 | Traffic usage, accounting mode, limits and reset |

On Iran, **1 → 3** opens the selected tunnel's controls: start, stop, restart, service ports, name, foreign IP, GRE carrier, connection code, traffic, loss recovery, FRP protocol, MTU, control port and token. More than one foreign server can be registered on Iran; their public service ports on Iran must not overlap. A foreign server can also connect to several Iran servers independently, including when their service ports are identical. See [multiple Iran connections](docs/USAGE.md#connect-several-iran-servers-to-one-foreign-server).

## Traffic

Usage and limits use decimal **GB**: `1 GB = 1,000,000,000 bytes`. Download means received by the server where the counter runs; upload means sent by it. Choose download, upload or both for quota accounting. Normal GRE counters measure inner IPv4 traffic, so they do not equal the provider's billable wire traffic. The monitor samples every 10 seconds.

## Update

On Iran and each foreign endpoint:

```bash
NavaTunnel update-all
NavaTunnel
```

Read [upgrade notes](docs/OPERATIONS.md#upgrading-from-older-versions) if you used optional features in an older release. Ordinary GRE/FRP settings and counters are preserved during their retirement.

## Help

- [Step-by-step tunnel guide](docs/USAGE.md)
- [Traffic, security, backup, migration and troubleshooting](docs/OPERATIONS.md)
- [راهنمای فارسی](docs/USAGE.fa.md)
- `NavaTunnel --help` lists command-line options.

Released source is available in this repository. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).
