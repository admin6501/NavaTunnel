# Third-party source notices

NavaTunnel includes code adapted from **pdnczone/hashem-panel**, maintained by its original authors and contributors:

- Source: https://github.com/pdnczone/hashem-panel
- Reviewed revision: `fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7` (v2.3.6, 2026-10-18).
- License: GNU Affero General Public License, version 3. See [LICENSE](LICENSE).

The `core/upstream_*.go` files contain selected original backend declarations and adapted original tests. Shell Auto Pool, dial-routing and memory-scaling helpers, and their shell tests, also derive from this revision. The original authors retain their copyrights. NavaTunnel changes include a standalone CLI/Unix-socket runtime, English terminal menus, integration with the existing tunnel registry, authenticated interserver endpoints, TLS certificate pinning, dedicated transactional firewall chains, error handling, race fixes, protocol-port fixes, opt-in defaults and integration tests. These changes do not transfer ownership of the original work.

No browser application, web administration panel, Backhaul installer/binary, Sentinel web application or paid activation service is shipped. The optional TLS listener is limited to authenticated interserver operations and bearer-authenticated metrics; local administration uses a root-only Unix socket. Upstream branding may appear in source provenance, retained protocol formats and original historical error identifiers. This notice and the AGPL license must remain with redistributions.

The standalone runtime depends on `github.com/gorilla/websocket` v1.5.3, distributed under the BSD 2-Clause license: https://github.com/gorilla/websocket/blob/v1.5.3/LICENSE . Its copyright and license are included in `core/WEBSOCKET_LICENSE`.

Release binaries are built from the corresponding tagged source in this repository; the complete modified source and build commands are publicly available here.
