# Retained upstream source

NavaTunnel retains the original Cluster backend from pdnczone/hashem-panel revision `fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7`, adapted for a root-only local CLI and authenticated TLS mesh heartbeat listener. Its foreign exit pool, weights, failover and lowest-latency selection, Iran mesh and firewall isolation remain available. NavaLink retains FRP-over-SSH and TCP-only Direct modes.

At the user's request, the other features added in 1.1.0 have been removed, including the GRE WSS bridge, Rescue, Auto Pool, reverse-path doctor, benchmark/Auto Pilot, history, metrics, independent alerts, Peer Link, dial-route helpers and separate network-tools menu. Their Go implementations, CLI routes, background collectors and menu pages are removed. Main tunnel management, existing FRP protocols, quotas, MTU, backup/restore and the pre-existing shell maintenance tools remain.

See [the setup guide](UPSTREAM_TOOLS.md) for current behavior and [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md) for source provenance. No browser administration panel, Backhaul runtime or paid activation service is included.
