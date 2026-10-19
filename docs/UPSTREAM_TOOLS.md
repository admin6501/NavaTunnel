# Cluster and NavaLink

Update Iran and each foreign server with `NavaTunnel update-all`, then reopen `NavaTunnel`.

The retained optional menus are **2 → 9: NavaLink** and **2 → 10: Cluster**. The former multi-tool menu and all other added 1.1.0 tools have been removed. Normal GRE/FRP management, saved MTU, traffic quotas, backup/restore, migration, the existing shell watchdog and DPI/chaff controls remain available.

## Cluster: one Iran with several exits

Each exit must already have a reachable application listener and compatible user/inbound settings. Cluster does not replicate users or create additional FRPC instances. Start with a test port.

On Iran, open **2 → 10**:

1. Option 2: enter public service ports and select `failover`, `wrr` or `lowest_latency`.
2. Option 3: import an existing GRE peer. The destination is its foreign **private GRE IP**. Enter a TCP application port that really listens on that destination, not the FRPS control port.
3. Repeat for each exit; option 4 also accepts a reachable address and optional entry-to-destination port mapping.
4. Option 6: choose the preferred exit for failover mode.
5. Option 10: start the retained core and enable routing. Option 1 shows status; option 11 disables routing.

`failover` picks a healthy alternative when the preferred exit becomes unavailable. `wrr` distributes new flows by weight; `lowest_latency` selects a healthy exit with the lowest measured TCP-connect delay. A successful probe of one application port does not test every port or guarantee a packet-loss percentage. Existing connections may need to reconnect after switching.

Cluster uses kernel DNAT/SNAT and dedicated `NAVA-CLUSTER-*` chains. A GRE exit may reach the foreign application directly rather than using FRP's reverse data path. GRE/FOU alone do not encrypt payloads; application TLS or an encrypted path is needed where appropriate. Provider firewalls still need to allow traffic. Existing quota rules remain in place.

## Cluster: several Iran nodes

Every Iran needs its own working exit path and service configuration. On each Iran:

1. Option 7: configure a unique node ID and local public IP, using the same private shared secret (at least 24 characters) on trusted nodes.
2. Option 12: enable the TLS heartbeat listener and obtain its certificate fingerprint. Permit the listener only from intended peers where possible.
3. Option 8: register the other Iran's node ID, public IP, TLS heartbeat URL and fingerprint. Configure both directions.
4. Inspect status, then enable routing with option 10.

The original monitor exchanges authenticated heartbeat messages. The retained local health check inspects established FRP control sessions and NavaLink state; unknown local observations do not count as recovery. It is a coarse UP/DOWN signal rather than a precise packet-loss measurement. Exit-pool probes remain separate.

If the first Iran's outgoing path fails while that Iran can still receive user traffic and reach its alternative, it can hand traffic to a healthy Iran. A fully unreachable server cannot forward packets it never receives; client or DNS failover is needed for that case. Option 13 reverts a mesh handoff.

## NavaLink

Open **2 → 9 → 1** on Iran. Choose `frp` for TCP/UDP over SSH, or `direct` for TCP-only local SSH forwarding. Enter the foreign SSH address/port, Iran public IP and unused service ports. Root SSH authentication follows the normal agent/key/password flow; host keys are verified. A dedicated restricted forwarding account is used afterward.

For an existing GRE tunnel, choose its ID to convert it in FRP mode. Its configuration and quota are retained for rollback. Direct mode uses a separate connection and does not silently discard UDP from an existing tunnel. Use its menu to inspect, start, stop, restart, change a peer address, view logs or remove locally. See [the detailed guide](ADVANCED.md).

## Runtime and backups

The optional core now contains only Cluster, its TLS heartbeat/control plumbing and the small TLS front needed by the existing FRP WSS transport. It has no history collectors, standalone alerts, metrics, diagnostics, Auto Pilot, Rescue, Peer Link or GRE WSS relay. No Go installation is required on the server; the script fetches checksum-verified binaries from the `core-v1.1.1` release when needed.

`NavaTunnel core-service start` starts the private Unix control socket. `NavaTunnel core-service start --listen 0.0.0.0:47777` explicitly enables the TLS Cluster heartbeat listener. No web administration routes are mounted. Cluster configuration and certificate identity are included in encrypted backups.

Removed 1.1.0 settings are privately archived under `/var/backups/navatunnel/removed-tools-*`; only their owned services and Rescue nftables tables are retired. Cluster, NavaLink, main FRP files and quota state are retained. Current FRP address/pool values are not automatically retuned by this migration. An active removed GRE WSS relay is moved to the existing FOU carrier; update both endpoints when retiring such a relay. FRP WSS remains a supported pre-existing protocol and uses its own TLS front.
