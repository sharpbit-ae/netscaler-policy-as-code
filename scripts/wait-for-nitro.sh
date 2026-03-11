#!/usr/bin/env bash
# wait-for-nitro.sh — Poll NITRO API until VPX is responsive
# Tries HTTPS first (works on configured VPXs), falls back to HTTP (fresh VPXs)
set -euo pipefail

NSIP="${1:?Usage: $0 NSIP PASSWORD [MAX_WAIT_SECONDS]}"
PASSWORD="${2:?Missing PASSWORD}"
MAX_WAIT="${3:-180}"

ELAPSED=0
INTERVAL=10

echo "=== Waiting for NITRO API at $NSIP (timeout: ${MAX_WAIT}s) ==="

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    # Try HTTPS first (configured VPXs have gui SECUREONLY)
    HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
        -H "Content-Type: application/json" \
        -H "X-NITRO-USER: nsroot" \
        -H "X-NITRO-PASS: $PASSWORD" \
        "https://${NSIP}/nitro/v1/config/nsversion" 2>/dev/null) || HTTP_CODE=0

    if [[ "$HTTP_CODE" == "200" ]]; then
        echo "  NITRO API responsive after ${ELAPSED}s (HTTPS $HTTP_CODE)"
        echo "=== NITRO API $NSIP is ready ==="
        exit 0
    fi

    # Fall back to HTTP (fresh VPXs may not have HTTPS configured yet)
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Content-Type: application/json" \
        -H "X-NITRO-USER: nsroot" \
        -H "X-NITRO-PASS: $PASSWORD" \
        "http://${NSIP}/nitro/v1/config/nsversion" 2>/dev/null) || HTTP_CODE=0

    if [[ "$HTTP_CODE" == "200" ]]; then
        echo "  NITRO API responsive after ${ELAPSED}s (HTTP $HTTP_CODE)"
        echo "=== NITRO API $NSIP is ready ==="
        exit 0
    fi

    echo "  Waiting... (${ELAPSED}s / ${MAX_WAIT}s) [HTTP $HTTP_CODE]"
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo "ERROR: NITRO API at $NSIP did not respond within ${MAX_WAIT}s"
exit 1
