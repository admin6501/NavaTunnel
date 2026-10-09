#!/usr/bin/env bash
# Random GRE cover traffic; this also runs while user traffic is active.
PEER_IP="${1:-}"
PROFILE="${2:-low}"
case "$PROFILE" in
 low) MIN_MS=400; MAX_MS=2800; MIN_BYTES=64; MAX_BYTES=1200 ;;
 mid) MIN_MS=150; MAX_MS=1200; MIN_BYTES=200; MAX_BYTES=1280 ;;
 custom) MIN_MS=${3:-}; MAX_MS=${4:-}; MIN_BYTES=${5:-}; MAX_BYTES=${6:-} ;;
 *) echo 'حالت ترافیک پوششی نامعتبر است.' >&2; exit 1 ;;
esac
[[ -n "$PEER_IP" ]] || { echo 'IP داخلی مقابل را وارد کنید.' >&2; exit 1; }
for value in "$MIN_MS" "$MAX_MS" "$MIN_BYTES" "$MAX_BYTES"; do
 [[ "$value" =~ ^[0-9]{1,7}$ ]] || { echo 'محدوده ترافیک پوششی نامعتبر است.' >&2; exit 1; }
done
MIN_MS=$((10#$MIN_MS)); MAX_MS=$((10#$MAX_MS)); MIN_BYTES=$((10#$MIN_BYTES)); MAX_BYTES=$((10#$MAX_BYTES))
((MIN_MS>=100 && MAX_MS<=3600000 && MIN_MS<=MAX_MS && MIN_BYTES>=8 && MAX_BYTES<=1352 && MIN_BYTES<=MAX_BYTES)) || { echo 'محدوده ترافیک پوششی نامعتبر است.' >&2; exit 1; }
trap 'exit 0' SIGTERM SIGINT
while true; do
 ms=$(( MIN_MS + ((RANDOM<<15)|RANDOM) % (MAX_MS-MIN_MS+1) ))
 size=$(( MIN_BYTES + RANDOM % (MAX_BYTES-MIN_BYTES+1) ))
 sleep_sec=$(printf '%d.%03d' $((ms/1000)) $((ms%1000)))
 sleep "$sleep_sec"
 pattern=$(printf '%04x%04x%04x%04x' "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM")
 ping -n -c1 -W1 -s "$size" -p "$pattern" "$PEER_IP" >/dev/null 2>&1 || true
done
