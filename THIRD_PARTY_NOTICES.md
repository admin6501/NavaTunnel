# Third-party source notices

NavaTunnel includes Bash code derived from [pdnczone/hashem-panel](https://github.com/pdnczone/hashem-panel). The original authors and contributors retain their copyrights. The project is distributed under GNU AGPL-3.0; see [LICENSE](LICENSE).

The small FRP WSS TLS helper in `core/tls_proxy.go` and `core/certificate.go` was adapted from revision `fb4d072d5a06f83c42d8ba62df2d7a53f25f6ce7` of that upstream project. The helper only terminates TLS and forwards the stream to FRPS. Source attribution comments are retained in these files.

NavaTunnel's management menus, traffic quotas, migration and maintenance changes are available as modified source in this repository. Historical connection-code identifiers and state paths remain compatible with existing installations.

FRP executables are downloaded separately from [fatedier/frp](https://github.com/fatedier/frp), which is licensed under Apache-2.0. The Go TLS helper uses only the Go standard library. Release binaries are built from their matching public source tag using the repository's release workflow.
