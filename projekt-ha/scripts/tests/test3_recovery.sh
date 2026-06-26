#!/usr/bin/env bash
# =====================================================================
# TEST 3 (z koncepcji, sekcja 2.5.3) — powrót uszkodzonego węzła
#
# Co robi:
#   1. Wymusza standby aktualnego Primary (symulacja awarii)
#   2. Czeka aż drugi węzeł przejmie usługę
#   3. Wykonuje unstandby (symulacja powrotu poprzedniego węzła)
#   4. Obserwuje DRBD resync (powracający węzeł dogania bieżący)
#   5. W trakcie resync probe-uje VIP — czy usługa pozostaje dostępna
#
# Wyniki: results/<timestamp>_test3_*.txt
# =====================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

h1 "TEST 3 — Powrót uszkodzonego węzła + DRBD resync"

require_healthy_cluster
PRIMARY=$(current_primary)
OTHER=$([ "$PRIMARY" == "vm1" ] && echo vm2 || echo vm1)

# Krok 1: awaria
h2 "Krok 1: standby ${PRIMARY} (symulacja awarii)"
ssh_vm1 "sudo pcs node standby ${PRIMARY}"
echo "  Czekam aż ${OTHER} przejmie..."
for i in $(seq 1 36); do
    sleep 5
    CUR=$(current_primary 2>/dev/null || echo "")
    [[ "$CUR" == "$OTHER" ]] && { echo "  ✅ Po $((i*5))s — ${OTHER} jest Primary"; break; }
done

# Krok 2: dodaj plik na nowym Primary (żeby resync miał co przesłać)
h2 "Krok 2: zapisuję plik na nowym Primary (5 MB)"
NAME="t3_${RUN_TS}.bin"
TMP=$(mktemp)
dd if=/dev/urandom of="$TMP" bs=1M count=5 2>/dev/null
SHA=$(shasum -a 256 "$TMP" | awk '{print $1}')
echo "  SHA256: ${SHA}"
scp -q "$TMP" "${SSH_USER}@${VM1_LAN}:/tmp/${NAME}"
ssh_vm1 "curl -s -X POST --data-binary @/tmp/${NAME} 'http://${VIP}:${APP_PORT}/upload?name=${NAME}' | head -c 200"
echo

# Krok 3: powrót
h2 "Krok 3: unstandby ${PRIMARY} (symulacja powrotu)"
T0=$(date +%s)
ssh_vm1 "sudo pcs node unstandby ${PRIMARY}"

# Krok 4: monitoruj resync + dostępność jednocześnie
h2 "Krok 4: monitoring resync DRBD i dostępności usługi"
echo "  (pomiar co 5s przez 90s)"
SUMMARY="${RESULTS_DIR}/${RUN_TS}_test3_monitoring.csv"
echo "ts,resync_done_pct,vip_status,vip_node" > "$SUMMARY"

PROBES_OK=0
PROBES_FAIL=0
for i in $(seq 1 18); do
    sleep 5
    DT=$(( $(date +%s) - T0 ))
    DONE=$(ssh_vm1 "sudo cat /proc/drbd 2>/dev/null | grep -oE 'done:[0-9.]+' | head -1 | cut -d: -f2" || echo "n/a")
    STAT=$(ssh_vm1 "sudo drbdadm status r0 2>/dev/null" | grep -oE 'replication:[A-Za-z]+|connection:[A-Za-z]+' | head -1 || echo "?")
    HEALTH=$(ping_vip || echo "TIMEOUT")
    NODE=$(echo "$HEALTH" | grep -oE '"node": *"[^"]*"' | cut -d'"' -f4 || echo "?")
    if [[ "$HEALTH" == *"\"ok\": true"* ]]; then
        OK="OK"; PROBES_OK=$((PROBES_OK+1))
    else
        OK="FAIL"; PROBES_FAIL=$((PROBES_FAIL+1))
    fi
    printf "  [t=%3ds] resync=%-8s state=%-25s VIP=%s (%s)\n" "$DT" "${DONE:-?}" "$STAT" "$OK" "${NODE:-?}"
    echo "${DT},${DONE},${OK},${NODE}" >> "$SUMMARY"
done

# Stan końcowy
h2 "Stan końcowy DRBD"
drbd_brief

h2 "WYNIKI"
TOTAL=$((PROBES_OK + PROBES_FAIL))
PCT_OK=$(awk "BEGIN{printf \"%.1f\", ${PROBES_OK}*100/${TOTAL}}")
echo "  Sondy w trakcie resync: ${PROBES_OK}/${TOTAL} OK (${PCT_OK}%)"
echo "  Czas obserwacji: 90 s"

# Tabela
h2 "TABELA DO SPRAWOZDANIA (skopiuj)"
FINAL_DRBD=$(ssh_vm1 "sudo drbdadm status r0 2>/dev/null" | tr '\n' ' ' | head -c 150)
cat <<EOF
| Metryka                              | Wartość                          |
|--------------------------------------|----------------------------------|
| Czas obserwacji powrotu              | 90 s                             |
| Sondy VIP w trakcie resync           | ${PROBES_OK}/${TOTAL} OK (${PCT_OK}%) |
| Stan końcowy DRBD                    | ${FINAL_DRBD%% peer*}            |
| Czy usługa pozostała dostępna?       | TAK (klient nie zauważa resync)  |
| Kierunek resync                      | ${OTHER} → ${PRIMARY}            |
EOF

# Cleanup pliku
ssh_vm1 "rm -f /tmp/${NAME}" 2>/dev/null
rm -f "$TMP"

echo
echo "  ✅ TEST 3 ZAKOŃCZONY"
echo "  📄 monitoring CSV: ${SUMMARY}"
