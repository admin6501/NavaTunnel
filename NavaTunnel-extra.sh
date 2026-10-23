#!/usr/bin/env bash
# Compatibility entrypoint for releases whose updater fetched this filename.
# No optional engine remains here. Retirement runs after the new main script loads.
set -euo pipefail
case "${1:-}" in
    cleanup-retired|cleanup-extra-tools) exit 0 ;;
    *) echo 'This helper was retired. Run NavaTunnel update-all, then reopen NavaTunnel.' >&2; exit 1 ;;
esac
