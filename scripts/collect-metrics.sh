#!/usr/bin/env bash
# collect-metrics.sh — Background resource monitor
# Samples CPU, memory, disk, and network every INTERVAL seconds to a CSV file.
# Usage: collect-metrics.sh OUTPUT_CSV [INTERVAL_SECS] [INTERFACE]
#   Start: scripts/collect-metrics.sh /path/to/metrics.csv 10 &
#   Stop:  kill "$(cat /path/to/metrics.csv.pid)"
set -euo pipefail

OUTPUT_CSV="${1:?Usage: $0 OUTPUT_CSV [INTERVAL] [INTERFACE]}"
INTERVAL="${2:-10}"
INTERFACE="${3:-}"

# Auto-detect primary network interface if not specified
if [[ -z "$INTERFACE" ]]; then
    INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}') || true
    [[ -z "$INTERFACE" ]] && INTERFACE="lo"
fi

# Write PID file for easy shutdown
echo $$ > "${OUTPUT_CSV}.pid"
trap 'rm -f "${OUTPUT_CSV}.pid"' EXIT

# Write CSV header
echo "timestamp,cpu_pct,mem_used_mb,mem_total_mb,mem_pct,disk_used_gb,disk_total_gb,disk_pct,net_rx_mbps,net_tx_mbps" > "$OUTPUT_CSV"

# Read CPU counters from /proc/stat (total_ticks idle_ticks)
read_cpu() {
    awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat
}

# Read network byte counters for interface
read_net() {
    awk -v iface="${INTERFACE}:" '$1 == iface {print $2, $10}' /proc/net/dev
}

# Initial readings for delta calculation
read -r PREV_TOTAL PREV_IDLE <<< "$(read_cpu)"
read -r PREV_RX PREV_TX <<< "$(read_net)" 2>/dev/null || { PREV_RX=0; PREV_TX=0; }
PREV_TIME_NS=$(date +%s%N)

while true; do
    sleep "$INTERVAL"

    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    NOW_NS=$(date +%s%N)

    # --- CPU percentage (delta since last sample) ---
    read -r CURR_TOTAL CURR_IDLE <<< "$(read_cpu)"
    TOTAL_DIFF=$(( CURR_TOTAL - PREV_TOTAL ))
    IDLE_DIFF=$(( CURR_IDLE - PREV_IDLE ))
    if [[ $TOTAL_DIFF -gt 0 ]]; then
        CPU_PCT=$(awk "BEGIN {printf \"%.1f\", 100 * (1 - $IDLE_DIFF / $TOTAL_DIFF)}")
    else
        CPU_PCT="0.0"
    fi
    PREV_TOTAL=$CURR_TOTAL
    PREV_IDLE=$CURR_IDLE

    # --- Memory ---
    MEM_TOTAL=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    MEM_AVAIL=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    MEM_USED_MB=$(( (MEM_TOTAL - MEM_AVAIL) / 1024 ))
    MEM_TOTAL_MB=$(( MEM_TOTAL / 1024 ))
    MEM_PCT=$(awk "BEGIN {printf \"%.1f\", 100.0 * $MEM_USED_MB / $MEM_TOTAL_MB}")

    # --- Disk (root filesystem) ---
    read -r DISK_USED_GB DISK_TOTAL_GB DISK_PCT <<< "$(df -BG / | awk 'NR==2 {
        gsub(/G/, "", $2); gsub(/G/, "", $3); gsub(/%/, "", $5);
        print $3, $2, $5
    }')"

    # --- Network throughput ---
    read -r CURR_RX CURR_TX <<< "$(read_net)" 2>/dev/null || { CURR_RX=$PREV_RX; CURR_TX=$PREV_TX; }
    ELAPSED_NS=$(( NOW_NS - PREV_TIME_NS ))
    if [[ $ELAPSED_NS -gt 0 ]]; then
        RX_BYTES=$(( CURR_RX - PREV_RX ))
        TX_BYTES=$(( CURR_TX - PREV_TX ))
        RX_MBPS=$(awk "BEGIN {printf \"%.2f\", $RX_BYTES / ($ELAPSED_NS / 1000000000) / 1048576}")
        TX_MBPS=$(awk "BEGIN {printf \"%.2f\", $TX_BYTES / ($ELAPSED_NS / 1000000000) / 1048576}")
    else
        RX_MBPS="0.00"
        TX_MBPS="0.00"
    fi
    PREV_RX=$CURR_RX
    PREV_TX=$CURR_TX
    PREV_TIME_NS=$NOW_NS

    # Append CSV row
    echo "$NOW,$CPU_PCT,$MEM_USED_MB,$MEM_TOTAL_MB,$MEM_PCT,$DISK_USED_GB,$DISK_TOTAL_GB,$DISK_PCT,$RX_MBPS,$TX_MBPS" >> "$OUTPUT_CSV"
done
