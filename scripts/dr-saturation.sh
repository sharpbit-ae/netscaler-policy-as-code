#!/usr/bin/env bash
# dr-saturation.sh — Background data plane probe during DR cycle
# Sends HTTP GET to VIP every N seconds, logs timestamp + status
# Usage: dr-saturation.sh VIP LOGFILE [INTERVAL]
set -u

VIP="${1:?Usage: $0 VIP LOGFILE [INTERVAL]}"
LOGFILE="${2:?Missing LOGFILE}"
INTERVAL="${3:-2}"

echo "# DR Saturation Probe — VIP: ${VIP}, Interval: ${INTERVAL}s" > "$LOGFILE"
echo "# Format: epoch_seconds,http_status,response_time_ms" >> "$LOGFILE"
echo "# Started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$LOGFILE"

while true; do
    TIMESTAMP=$(date -u +%s)
    RESULT=$(curl -sk --connect-timeout 5 --max-time 10 \
        -o /dev/null -w "%{http_code},%{time_total}" \
        "https://${VIP}/get" 2>/dev/null) || RESULT="000,0"

    HTTP_CODE=$(echo "$RESULT" | cut -d, -f1)
    RESPONSE_TIME=$(echo "$RESULT" | cut -d, -f2)
    RESPONSE_MS=$(python3 -c "print(int(float('${RESPONSE_TIME}') * 1000))" 2>/dev/null || echo "0")

    echo "${TIMESTAMP},${HTTP_CODE},${RESPONSE_MS}" >> "$LOGFILE"

    sleep "$INTERVAL"
done
