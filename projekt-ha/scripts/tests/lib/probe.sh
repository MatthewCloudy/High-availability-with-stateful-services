#!/bin/bash
# =====================================================================
# Sonda HTTP — wysyła GET /health co 0.5s przez podany czas.
# Output CSV: ts,code,latency_ms,body_node
# Używana przez Test 1 i Test 5.
# =====================================================================
DURATION="${1:-180}"  # sekundy
VIP="${2:-10.0.0.100}"
OUT="${3:-/tmp/probe.csv}"
PORT=8080

echo "ts,code,latency_ms,body_node" > "$OUT"
START=$(date +%s.%N)
END_AT=$(awk "BEGIN{print $START + $DURATION}")

while :; do
    NOW=$(date +%s.%N)
    REL=$(awk "BEGIN{printf \"%.2f\", $NOW - $START}")
    awk -v n="$NOW" -v e="$END_AT" 'BEGIN{exit (n>=e)?0:1}' && break

    RES=$(curl -s -o /tmp/body.$$ -w "%{http_code} %{time_total}" --max-time 2 \
              http://"$VIP":"$PORT"/health 2>/dev/null)
    CODE=$(echo "$RES" | awk '{print $1}')
    LAT=$(echo "$RES" | awk '{printf "%.0f", $2*1000}')
    BODY=$(grep -oE '"node": *"[^"]*"' /tmp/body.$$ 2>/dev/null | cut -d'"' -f4)
    echo "$REL,$CODE,$LAT,${BODY:-?}" >> "$OUT"
    sleep 0.5
done

rm -f /tmp/body.$$
