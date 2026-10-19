# Standalone networking tools

Update **both** endpoints with `NavaTunnel update-all`, then reopen `NavaTunnel`. Go is not required on servers. The optional standalone core is downloaded from this repository's `core-v1.1.0` release, checked against its SHA256 manifest and executed only when requested. Source is under `core/`; build with Go 1.23 or later: `cd core && go build -o NavaTunnel-core .`.

Open **2) Advanced settings → 11) Cluster, WSS, Rescue, Auto Pool and monitoring tools**. Every new screen is in English. Existing GRE/FRP/NavaLink management, counters and backups continue to work. Neither Cluster nor automatic carrier switching is silently enabled by updating.

## Cluster: what the two modes actually do

This is the original project's networking backend, adapted without its panel. It has two independent parts:

- **One Iran entry, several foreign exits:** register reachable backend addresses and application ports. Choose `failover`, `wrr` (weighted new connections), or `lowest_latency`. A TCP-connect probe determines eligibility; it is not a continuous end-to-end packet-loss SLA. Import existing GRE peers to use their **foreign private GRE IP**, not their public address or FRPS control port. Enter an application TCP port which really listens on that foreign server. All service ports you publish must exist on the selected exits, with compatible client credentials/inbounds.
- **Several Iran nodes:** each node runs the standalone core, has its own working outgoing service path, a unique node ID, the same mesh secret and service ports. Add peers with their public address and authenticated TLS API URL/fingerprint. Heartbeats report tunnel health; when the original monitor confirms local failure and a healthy alternative, the entry forwards new traffic to that alternative Iran. This does not configure the alternative's tunnels for you.

For the first mode: menu **1 → 2** sets entry service ports and mode; **3** imports an existing GRE exit (or **4** adds an address and optional port mapping); **10** starts the daemon and enables routing. Start with one test port. **11** disables owned routing; **13** reverts an active mesh handoff. Client addresses change through SNAT; existing connections may need to reconnect after switching.

For an Iran mesh: on every Iran configure **1 → 7** with its unique ID/public IP and an identical random secret of at least 24 characters. Enable its TLS peer listener with **12**, record the SHA256 certificate fingerprint, and permit that port only from intended peers in your provider firewall. Add the other Iran under **8**, including its URL and fingerprint. Complete this on both sides, inspect status, then enable. A server that is completely unreachable from clients cannot redirect packets it never receives: client/DNS failover is still needed for that case.

Cluster uses kernel DNAT/SNAT. A GRE exit route can bypass the FRP reverse data path and reach the foreign application directly over GRE. GRE/FOU alone do not encrypt payloads: use application TLS or an encrypted carrier where needed. Several Iran nodes can target the same reachable application, but Cluster does **not** provision several FRPC instances on a foreign host. Account/inbound replication is your responsibility. It also cannot guarantee that an upstream loss event disappears.

Only private `NAVA-CLUSTER-*` chains and its marked flows are managed. Existing provider firewalls still need the traffic allowed. The menu displays selected/configured state, which is not a guarantee that every application port has been tested.

## WSS: carrier versus FRP transport

These are different features:

- **FRP WSS transport:** select WSS for a tunnel, then reapply its foreign bundle. Iran uses a small TLS front at `control + 2` (or `control - 2` near the port maximum). This forwards to that tunnel's existing FRPS control port. Keep the front port free and reachable.
- **WSS carrier for GRE:** configure **11 → 2** on both endpoints with server/client roles, matching token (at least 24 characters), listener/remote address, SNI and a selected GRE interface. Start the relay, then select the matching WSS carrier on both ends. One WSS GRE bridge per host is supported; other GRE peers retain their carriers. It uses the original FOU/UDP-to-WebSocket bridge. Local bridge ports 19998/19999 must be free. Configure the same MTU on both ends. A self-signed relay certificate requires an explicit client choice to allow it; do not assume public WebPKI validation will trust it.

WSS is TLS transport; it does not make traffic invisible or guarantee DPI evasion. Encapsulation, TLS and any retransmissions consume additional bytes.

## NavaLink modes

The existing NavaLink menu now offers **FRP** (default, forwards TCP and UDP over its SSH carrier) and **direct** (SSH local forwarding, **TCP only**). Direct mode binds the chosen service ports on Iran and forwards them to the same localhost ports on foreign. It creates no FRP data path. Use unused service ports and separately configured application listeners. Existing GRE conversions retain FRP mode so UDP/custom proxy options are not silently dropped. The dedicated SSH account has no interactive shell, no agent forwarding and only the specific forwarding direction/destinations allowed. Keys and verified host fingerprints remain required. FRP-mode pool size is configurable per link; default 20.

## Rescue

**11 → 3** carries the original one-way connectivity recovery backend. The blocked/origin side creates a private connection code; enter it on a reachable entry server. Their service ports and application path must already be correct. It uses FRP services and dedicated nftables tables; install `nftables` and verified FRP binaries first (`NavaTunnel download-cores`). The operation checks prerequisites and reports failures. Codes contain credentials. Use status/probe first; automatic activation is a separate explicit choice. Disable removes owned Rescue units/rules. A successful restore does not by itself repair all opposite endpoint addresses.

## Auto Pool, dial route and performance

**11 → 4** controls the original Auto Pool algorithm. It is initially off. Once enabled, the watchdog samples each minute, scales pool size within bounds, and uses cooldown, quiet-sample, CPU, RAM and active-connection gates before restarting FRPC. A restart can briefly interrupt sessions. FRPS maximum changes may still require a planned server restart; status reports that. Manual pool changes and tcpMux need coordinated endpoints. A `work connection pool is full` log alone does not prove that a larger pool will help.

**11 → 10** or `NavaTunnel dial status|gre|public|auto` controls the foreign FRPC destination. Automatic mode may fall back from a failed GRE control path to Iran's public IPv4; that public control listener must be reachable and allowed. It keeps a working public connection rather than forcing an automatic return; use `dial gre` to switch back deliberately. After migration, reapply the new connection bundle to refresh both addresses/base control-port metadata.

Optimize uses RAM-scaled values and merges, rather than overwrites, existing `ip_local_reserved_ports`. MTU/MSS rules are managed per interface. None of these controls removes physical path loss.

## Diagnosis and linked changes

**11 → 5** offers reverse-path analysis, a repair preview, explicit repair and repair history. The full doctor can start an owned iperf3 server bound to the GRE address; install iperf3 separately if needed. Remote probes, paired carrier changes, benchmarks and Auto Pilot use **11 → 9** peer linking. Configure master/worker, the same private peer secret, opposite TLS API URL and fingerprint. Test the link before applying changes. Auto Pilot is opt-in and can interrupt connections while switching a carrier. Both endpoints must support the selected carrier and have matching relay settings.

Benchmark/advisor output is a measurement and recommendation, not an automatic promise of better throughput. The existing MTU probe in the network menu is also available without the core.

## Reports, alerts and local security

Start background collection under **11 → 7 → 6**. The core preserves up to 24 hours of link samples and seven days of traffic history. Those reports are separate from existing persistent quota counters; a seven-day history is not a billing total. The original peer history covers its registered GRE topology; per-link NavaLink quota accounting remains in its own traffic controls.

State alerts under **11 → 8** can use a webhook or the Telegram bot already configured in the watchdog. They include state transitions and disk/RAM/certificate warnings with hysteresis. Nothing is sent until you configure/enable alerts; the test action explicitly sends a test. Resource thresholds follow the original defaults. Cover traffic and DPI controls remain in the existing advanced menus.

Reports can rotate/show a Prometheus token or disable scraping. To scrape remotely, enable the TLS peer listener and use `Authorization: Bearer TOKEN` on `/metrics`; protect the token and verify the certificate. Metrics names use `navatunnel_`. Error and audit logs are private, redacted and rotated; local CLI access is `NavaTunnel advanced errors status` / `audit status`. JSON output is intentionally available for automation.

`NavaTunnel core-service start` enables the root-only Unix control service without a public listener. `NavaTunnel core-service start --listen 0.0.0.0:47777` explicitly enables its TLS interserver listener. The listener provides authenticated peer/heartbeat routes and token-protected metrics, **no browser administration UI**. Administration uses `/etc/gre-panel/core.sock` (0600). Default CLI output hides secrets; reveal only intentionally with `--show-secrets`.

Encrypted backups include core configuration and peer certificate identity. Preserve the backup encryption key. Disabling the core disables Cluster routing but is not a request to stop standalone Rescue services; disable Rescue from its menu when desired. Full uninstall removes only the core's owned Cluster/Rescue resources before the existing tunnel cleanup.
