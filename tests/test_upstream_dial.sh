# SPDX-License-Identifier: AGPL-3.0-only
# Adapted upstream test; see THIRD_PARTY_NOTICES.md.
#!/usr/bin/env bash
# Regression: foreign client must be able to reach the Iran hub over its PUBLIC IP
# when the GRE inner address is dead (Spain peer: GRE no ping, FRP must still connect).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export PATH="$T/bin:$PATH" GREEN= YELLOW= RED= NC=
CONFIG_DIR="$T/etc"; mkdir -p "$CONFIG_DIR"
fail=0
ext() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$ROOT/NavaTunnel.sh"; }
for f in dial_env_file dial_env_write dial_env_get dial_conf_file dial_service dial_current_addr dial_current_port \
         dial_pick dial_apply_addr dial_reselect dial_env_ensure dial_gre_usable; do
  body="$(ext $f)"; [[ -n "$body" ]] || { echo "FAIL: $f missing"; exit 1; }; eval "$body"
done
# ping + /dev/tcp both fail => GRE dead
printf '#!/bin/sh\nexit 1\n' > "$T/bin/ping"; chmod +x "$T/bin/ping"

cat > "$CONFIG_DIR/frpc.toml" <<EOT
serverAddr = "10.14.0.1"
serverPort = 7091
EOT
dial_env_write auto frp 10.14.0.1 203.0.113.217

# auto + dead GRE => public
[[ "$(dial_pick auto 10.14.0.1 203.0.113.217 7091)" == 203.0.113.217 ]] || { echo "FAIL auto dead GRE must pick public"; fail=1; }
[[ "$(dial_pick gre 10.14.0.1 203.0.113.217 7091)" == 10.14.0.1 ]] || { echo "FAIL gre mode"; fail=1; }
[[ "$(dial_pick public 10.14.0.1 203.0.113.217 7091)" == 203.0.113.217 ]] || { echo "FAIL public mode"; fail=1; }

r="$(dial_reselect)"; [[ "$r" == "changed:203.0.113.217" ]] || { echo "FAIL reselect: $r"; fail=1; }
grep -q 'serverAddr = "203.0.113.217"' "$CONFIG_DIR/frpc.toml" || { echo "FAIL frpc.toml not rewritten"; fail=1; }
grep -q 'serverPort = 7091' "$CONFIG_DIR/frpc.toml" || { echo "FAIL port changed"; fail=1; }
r="$(dial_reselect)"; [[ "$r" == "same:203.0.113.217" ]] || { echo "FAIL idempotent: $r"; fail=1; }

# forced gre flips it back
r="$(dial_reselect gre)"; [[ "$r" == "changed:10.14.0.1" ]] || { echo "FAIL force gre: $r"; fail=1; }

# GRE alive => stays on GRE
printf '#!/bin/sh\nexit 0\n' > "$T/bin/ping"
[[ "$(dial_pick auto 10.14.0.1 203.0.113.217 8443)" == 10.14.0.1 ]] || { echo "FAIL live GRE must stay on GRE"; fail=1; }

[[ $fail -eq 0 ]] && echo "dial route: all OK"
exit $fail
