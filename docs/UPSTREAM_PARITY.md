# Upstream backend port

The audited source is pdnczone/hashem-panel at `fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7` (v2.3.6). This describes that revision, not future upstream updates. Attribution and licensing are in [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md).

| Upstream capability | NavaTunnel implementation / entry |
|---|---|
| GRE, direct GRE, FOU, per-peer FRP, TCP/UDP | Existing tunnel menu; existing peers retained |
| TCP, WebSocket, WSS, KCP, QUIC FRP transports | Per-tunnel protocol selection; WSS TLS front, QUIC offset handling |
| Pool sizes, encryption, compression, TLS, tcpMux | Existing performance menu / new manual capacity controls |
| Adaptive Auto Pool | Advanced → 11 → 4; original cooldown, load, RAM and restart gates, disabled initially |
| RAM-scaled sysctls and reserved service ports | Optimize; preserves pre-existing reserved ports |
| WSS carrier for GRE | Advanced → 11 → 2; original Go relay, one paired GRE interface per host |
| SSH-based carrier / direct SSH forwarding | NavaLink menu; FRP TCP+UDP over SSH or explicit TCP-only direct mode |
| Foreign exit pool: weighted, failover, lowest latency | Advanced → 11 → 1; original Cluster schema, generator and probes |
| Iran mesh heartbeat and automatic handoff | Same Cluster menu; original monitor, shared secret, added TLS pin verification |
| One-way connectivity Rescue, join code, optional automatic negotiation | Advanced → 11 → 3; original FRP/nftables backend |
| Reverse-path doctor, repair preview/apply/history, remote probe | Advanced → 11 → 5; original diagnosis/repair backend |
| Benchmark, carrier advisor, Auto Pilot | Advanced → 11 → 6; authenticated peer link required for paired changes |
| GRE/public/automatic FRPC dial route | Advanced → 11 → 10, `NavaTunnel dial` |
| Fleet status, 24-hour link history, seven-day traffic history | Advanced → 11 → 7; persistent collectors in the standalone core |
| State-change webhook/Telegram, resource/certificate warnings | Advanced → 11 → 8; disabled until configured |
| Peer Link authentication and certificate identity | Advanced → 11 → 9; root-controlled local configuration |
| Prometheus metrics | Reports → rotate token; optional TLS peer listener, bearer token required |
| Structured errors and rotated security audit | Reports → error/audit history; private local logs |
| Port/SNI suggestions, network stack report, GRE-bound iperf | Reports / reverse-path doctor |
| Traffic quota, accounting direction, reset and unblock | Existing per-tunnel menu; GB units and saved usage retained |
| Backup, restore, SSH migration, MTU/MSS, control port/token/IP editing | Existing NavaTunnel implementations retained and extended for the core |
| Watchdog, cover traffic, DPI shaping, scheduling | Existing advanced/watchdog menus retained |
| Browser UI, accounts/sessions/2FA/browser terminal, browser updater, donation popup | Excluded as web-panel features |
| Sentinel | Excluded: a separate embedded web application |
| Backhaul installer, engine activation and binaries | Excluded |
| Paid license activation/checks | Not included; the AGPL source license and attribution remain |

## Adaptation fixes

The upstream firewall operations ignored some failures and shared generic chain names. The port uses private `NAVA-CLUSTER-*` chains and a connmark namespace, rolls back failed rule transactions, and leaves unrelated rules intact. The three exit-selection modes actually select eligible exits; a local unknown health result does not trigger recovery. WSS runtime counters are synchronized. Performance saves preserve existing DPI/chaff/TLS keys. FRP transport changes retain the base control port, handle WSS/QUIC offsets, and report restart failures. No package manager process is killed to acquire a package lock. Public peer endpoints cannot use a browser-session authentication fallback.

The original mesh is connection forwarding, not replication of Xray accounts, inbound configurations, databases or complete tunnel deployments. Importing an existing GRE exit uses its private GRE address and an application probe port. Cluster does not create extra FRPC connections on a foreign server. Read [the operation guide](UPSTREAM_TOOLS.md) before enabling routing.

## Validation

CI runs Bash syntax/error checks, Python CLI/menu/backup/traffic regression tests, the original adapted Auto Pool and dial tests, Go tests with the race detector, and disposable kernel/SSH network labs. The labs pass real TCP and UDP through Cluster, remove an exit and verify failover, verify weighted routing and unrelated firewall preservation, carry a full-size datagram through WSS, reject an incorrect WSS token, and exercise NavaLink SSH restrictions. These tests do not reproduce every provider firewall, route, operating-system release or packet-loss pattern.
