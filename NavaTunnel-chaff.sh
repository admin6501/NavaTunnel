#!/usr/bin/env bash
# GRE idle-gap chaff: random ping to peer inner IP

PEER_IP="${1:-}"
if [[ -z "$PEER_IP" ]]; then
    echo "روش استفاده: $0 <peer_inner_ip> [low|mid]" >&2
    exit 1
fi

PROFILE="${2:-${CHAFF_PROFILE:-low}}"

trap 'exit 0' SIGTERM SIGINT

while true; do
    if [[ "$PROFILE" == "mid" ]]; then
        # mid: intervals 0.15-1.2s, size 200-1280 (fits within MTU 1380)
        ms=$(( 150 + RANDOM % 1051 ))
        sleep_sec=$(printf "%d.%03d" $((ms / 1000)) $((ms % 1000)))
        size=$(( 200 + RANDOM % 1081 ))
    else
        # کم (پیش‌فرض): intervals 0.4-2.8s, size 64-1200
        ms=$(( 400 + RANDOM % 2401 ))
        sleep_sec=$(printf "%d.%03d" $((ms / 1000)) $((ms % 1000)))
        size=$(( 64 + RANDOM % 1137 ))
    fi

    sleep "$sleep_sec"

    # 16 random hex bytes (32 hex characters)
    pattern=$(printf '%04x%04x%04x%04x%04x%04x%04x%04x' $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM)

    ping -c1 -W1 -s "$size" -p "$pattern" "$PEER_IP" >/dev/null 2>&1 || true
done
