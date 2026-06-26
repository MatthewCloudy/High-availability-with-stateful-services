#!/usr/bin/env bash
# =====================================================================
# Analizuje CSV z probe.sh i wypluwa metryki dla sprawozdania.
# Użycie: analyze_probe.sh <probe.csv>
# =====================================================================
CSV="${1:?podaj plik CSV}"

awk -F, '
NR==1 { next }                                # pomiń nagłówek
{
    ts=$1; code=$2; lat=$3; node=$4
    if (code=="200") {
        if (first_ok=="" || node != first_ok_node) {
            if (first_ok=="") first_ok = ts
            first_ok_node = node
        }
        last_ok = ts
        nodes[node]++
        sum_lat[node] += lat
        n_lat[node]++
        if (in_fail) {
            recovery_ts = ts
            recovery_node = node
            in_fail = 0
        }
    } else {
        if (!in_fail) {
            in_fail = 1
            fail_start = ts
        }
        fail_count++
    }
}
END {
    # Liczenie okresu niedostępności (od pierwszego fail do pierwszego recovery)
    printf "{\n"
    printf "  \"first_response_ts\": %s,\n", first_ok+0
    printf "  \"fail_start_ts\": %s,\n", fail_start+0
    printf "  \"recovery_ts\": %s,\n", recovery_ts+0
    printf "  \"unavailability_s\": %.2f,\n", recovery_ts - fail_start
    printf "  \"failed_requests\": %d,\n", fail_count+0
    printf "  \"recovery_node\": \"%s\",\n", recovery_node
    printf "  \"nodes_seen\": {"
    sep=""
    for (n in nodes) { printf "%s\"%s\": %d", sep, n, nodes[n]; sep=", " }
    printf "},\n"
    printf "  \"avg_latency_ms\": {"
    sep=""
    for (n in n_lat) { printf "%s\"%s\": %.1f", sep, n, sum_lat[n]/n_lat[n]; sep=", " }
    printf "}\n"
    printf "}\n"
}' "$CSV"
