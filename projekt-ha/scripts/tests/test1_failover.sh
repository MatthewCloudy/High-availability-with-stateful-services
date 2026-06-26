#!/usr/bin/env bash
# =====================================================================
# TEST 1 (z koncepcji, sekcja 2.5.1) — awaria aktywnego węzła
#
# Co robi:
#   - probe co 0.5s przez 180s na VIP /health
#   - w t=10s wymuszamy standby aktualnego Primary (symulacja awarii)
#   - mierzymy: niedostępność, liczbę błędnych żądań, czas do recovery
#   - klient cały czas używa tego samego adresu (VIP)
#   - po teście: unstandby (klaster wraca do stanu wyjściowego)
#
# Wyniki: results/<timestamp>_test1_*.txt
# =====================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

h1 "TEST 1 — Awaria aktywnego węzła (failover automatyczny)"

require_healthy_cluster

# Aktualny Primary - to on padnie
PRIMARY=$(current_primary)
OTHER=$([ "$PRIMARY" == "vm1" ] && echo vm2 || echo vm1)
echo "  Primary: ${PRIMARY}  →  awarię symulujemy przez 'pcs node standby ${PRIMARY}'"
echo "  Przejęcie powinno trafić na: ${OTHER}"

# Wgraj probe.sh na vm1
h2 "Setup: kopiowanie probe.sh na vm1"
scp -q "${SCRIPT_DIR}/lib/probe.sh" "${SSH_USER}@${VM1_LAN}:/tmp/probe.sh"
echo "  [ok]"

# Start probe w tle - 180s
h2 "Start probe (180s, co 0.5s)"
PROBE_OUT="${RESULTS_DIR}/${RUN_TS}_test1_probe.csv"
ssh_vm1 'bash /tmp/probe.sh 180' &
PROBE_PID=$!
echo "  PID lokalnego ssh: ${PROBE_PID}"

# Czekamy 10s żeby zebrać baseline
sleep 10
T_FAIL=$(date +%s)
echo ""
echo "  >>> [t≈10s] WYMUSZAM AWARIĘ: sudo pcs node standby ${PRIMARY}"
ssh_vm1 "sudo pcs node standby ${PRIMARY}"
T_OK=$(date +%s)
echo "  >>> standby zaaplikowany ($((T_OK - T_FAIL))s)"

# Czekamy aż probe skończy
echo "  ... czekam aż probe skończy 180s ..."
wait $PROBE_PID 2>/dev/null || true

# Pobierz CSV
scp -q "${SSH_USER}@${VM1_LAN}:/tmp/probe.csv" "$PROBE_OUT"
echo "  [ok] probe.csv pobrane"

# Analiza
h2 "WYNIKI"
METRICS=$("${SCRIPT_DIR}/lib/analyze_probe.sh" "$PROBE_OUT")
echo "$METRICS"

# Stan po teście
h2 "Stan klastra po teście"
cluster_brief

# Cleanup
restore_cluster

# Tabela do sprawozdania
h2 "TABELA DO SPRAWOZDANIA (skopiuj)"
UNAV=$(echo "$METRICS" | grep -oE '"unavailability_s":[^,]*' | cut -d: -f2 | tr -d ' ')
FAILS=$(echo "$METRICS" | grep -oE '"failed_requests":[^,]*' | cut -d: -f2 | tr -d ' ')
RECNODE=$(echo "$METRICS" | grep -oE '"recovery_node": *"[^"]*"' | cut -d'"' -f4)
cat <<EOF
| Metryka                                | Wartość                          |
|----------------------------------------|----------------------------------|
| Czas niedostępności                    | ${UNAV} s                        |
| Liczba błędnych żądań                  | ${FAILS}                         |
| Pierwsza odpowiedź po failoverze z     | ${RECNODE}                       |
| Adres używany przez klienta            | ${VIP} (bez zmian)               |
EOF

save_result "test1_metrics" "$METRICS"
echo
echo "  ✅ TEST 1 ZAKOŃCZONY"
