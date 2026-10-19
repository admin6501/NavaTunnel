# Third-party source notices

NavaTunnel includes code adapted from **pdnczone/hashem-panel**, maintained by its original authors and contributors:

- Source: https://github.com/pdnczone/hashem-panel
- Reviewed revision: `fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7` (v2.3.6, 2026-10-18).
- License: GNU Affero General Public License, version 3. See [LICENSE](LICENSE).

The retained `core/upstream_cluster*.go` files contain the original Cluster backend and adapted tests. `core/certificate.go`, `core/upstream_crypto.go` and `core/upstream_tlsproxy.go` retain selected original TLS helpers. Original authors retain their copyrights. NavaTunnel changes include a standalone local CLI/Unix socket, English menus, integration with GRE/FRP/NavaLink health, TLS pin verification, dedicated transactional firewall chains and error handling. These changes do not transfer ownership of the original work.

The other backend tools introduced in 1.1.0 and the WebSocket dependency were removed in 1.1.1. No browser application, Backhaul engine, Sentinel web application or paid activation service is shipped. Source provenance and retained wire formats may preserve original historical identifiers. This notice and the AGPL license must remain with redistributions.

Release binaries are built from the corresponding tagged source in this public repository, including the modified source and build workflow.
