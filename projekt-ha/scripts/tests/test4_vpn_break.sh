#!/usr/bin/env bash
# =====================================================================
# TEST 4 (z koncepcji, sekcja 2.5.4) — zerwanie VPN
#
# Co robi:
#   1. Zatrzymuje WireGuard na vm2 (utrata łączności klastra przez tunel)
#   2. Obserwuje przez 60 s reakcję:
#        - DRBD wykryje rozłączenie peera (StandAlone)
#        - Pacemaker (po 2-node, no-quorum-policy=ignore) próbuje promotować
#          drugi węzeł → RYZYKO SPLIT-BRAIN: oba mogą być Primary
#   3. Przywraca WireGuard na vm2
#   4. Dokumentuje co się stało
#
# ⚠️ UWAGA: ten test świadomie doprowadza do split-brainu. Po nim
#    PRAWDOPODOBNIE trzeba uruchomić ./reset_after_splitbrain.sh
#
# Test jest dowodem na *udokumentowane ograniczenie* z koncepcji
# (sekcja 2.2 — "Ryzyko: Split-brain") oraz uzasadnia potrzebę
# trzeciego węzła / fencingu / qdevice.
# =====================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

h1 "TEST 4 — Zerwanie VPN i obserwacja split-brain"

require_healthy_cluster
PRIMARY_BEFORE=$(current_primary)
echo "  Primary przed testem: ${PRIMARY_BEFORE}"

cat <<'BANNER'

  ⚠️  UWAGA: ten test celowo zrywa tunel WireGuard między VM1 a VM2.
     Jest dużą szansą że doprowadzi do SPLIT-BRAIN (oba węzły Primary z
     różnymi danymi). To jest udokumentowane ograniczenie 2-node klastra
     bez fencingu / qdevice (sekcja "Ryzyko" w koncepcji projektu).

     Po teście prawdopodobnie konieczne będzie uruchomienie:
        ./reset_after_splitbrain.sh

BANNER
read -r -p "  Kontynuować? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Anulowano."; exit 0; }

# Krok 1: zatrzymaj WG na vm2
h2 "Krok 1: zatrzymuję WireGuard na vm2"
T0=$(date +%s)
ssh_vm2 "sudo systemctl stop wg-quick@wg0" || true
echo "  [ok] tunel WG zerwany od strony vm2 o $(date +%H:%M:%S)"

# Krok 2: monitoring przez 60s
h2 "Krok 2: monitoring (co 5 s przez 60 s)"
echo "  obserwuję: stan DRBD, stan Pacemakera, dostępność VIP"

MONITOR="${RESULTS_DIR}/${RUN_TS}_test4_monitor.csv"
echo "ts,drbd_vm1,drbd_vm2,vip_status" > "$MONITOR"

for i in $(seq 1 12); do
    sleep 5
    DT=$(( $(date +%s) - T0 ))

    DRBD_VM1=$(ssh_vm1 "sudo drbdadm status r0 2>/dev/null | tr '\n' ' '" 2>/dev/null | head -c 80)
    DRBD_VM2=$(timeout 5 ssh_vm2 "sudo drbdadm status r0 2>/dev/null | tr '\n' ' '" 2>/dev/null | head -c 80 || echo "(unreachable via WG)")
    HEALTH=$(ping_vip || echo "TIMEOUT")
    VIP_OK="FAIL"; [[ "$HEALTH" == *"\"ok\": true"* ]] && VIP_OK="OK"

    printf "  [t=%2ds] vm1:%-50s vm2:%-50s VIP:%s\n" "$DT" "$DRBD_VM1" "$DRBD_VM2" "$VIP_OK"
    echo "${DT},${DRBD_VM1},${DRBD_VM2},${VIP_OK}" >> "$MONITOR"
done

# Krok 3: przywróć WG
h2 "Krok 3: przywracam WireGuard na vm2"
ssh_vm2 "sudo systemctl start wg-quick@wg0" || true
sleep 5
echo "  [ok] tunel WG przywrócony"

# Sprawdź czy split-brain wystąpił
h2 "Krok 4: diagnostyka po teście"
DRBD_VM1_FINAL=$(ssh_vm1 "sudo drbdadm status r0 2>/dev/null")
DRBD_VM2_FINAL=$(timeout 10 ssh_vm2 "sudo drbdadm status r0 2>/dev/null" || echo "(VM2 nieosiągalna)")

echo "  --- vm1 ---"
echo "$DRBD_VM1_FINAL" | sed 's/^/    /'
echo "  --- vm2 ---"
echo "$DRBD_VM2_FINAL" | sed 's/^/    /'

SPLIT_BRAIN="NIE"
if echo "$DRBD_VM1_FINAL" | grep -qE "StandAlone|Primary.*Unknown"; then SPLIT_BRAIN="TAK (VM1 wykryło)"; fi
if echo "$DRBD_VM2_FINAL" | grep -qE "StandAlone|Primary.*Unknown"; then SPLIT_BRAIN="TAK (VM2 wykryło)"; fi

PRIMARIES_AFTER=$(echo "$DRBD_VM1_FINAL $DRBD_VM2_FINAL" | grep -oE 'role:Primary' | wc -l | tr -d ' ')

h2 "WYNIKI"
echo "  Stan przed testem:           1 Primary (${PRIMARY_BEFORE}), 1 Secondary"
echo "  Liczba Primary po teście:    ${PRIMARIES_AFTER}"
echo "  Split-brain wystąpił?        ${SPLIT_BRAIN}"
echo

if [[ "$PRIMARIES_AFTER" -ge "2" ]]; then
    cat <<'WARN'
  ❗ POTWIERDZENIE: nastąpił SPLIT-BRAIN.
     Oba węzły uważają się za Primary i mają niezgodne dane.
     To jest dokładnie ryzyko opisane w koncepcji (sekcja 2.2).

     KONIECZNY RESET: ./reset_after_splitbrain.sh
WARN
fi

# Tabela do sprawozdania
h2 "TABELA DO SPRAWOZDANIA (skopiuj)"
cat <<EOF
| Metryka                              | Wartość                          |
|--------------------------------------|----------------------------------|
| Mechanizm zerwania VPN               | systemctl stop wg-quick@wg0      |
| Czas obserwacji                      | 60 s                             |
| Liczba węzłów w stanie Primary       | ${PRIMARIES_AFTER}                |
| Split-brain wystąpił                 | ${SPLIT_BRAIN}                   |
| Wykrycie przez DRBD                  | StandAlone / Primary/Unknown     |
| Powód                                | Brak STONITH + brak quorum (2-node) |
| Lekarstwo w produkcji                | qdevice na 3. hoście (VPS)       |
EOF

save_result "test4_diagnosis" "$(cat <<EOF
primary_before=${PRIMARY_BEFORE}
primaries_after=${PRIMARIES_AFTER}
split_brain=${SPLIT_BRAIN}
drbd_vm1_final=${DRBD_VM1_FINAL}
drbd_vm2_final=${DRBD_VM2_FINAL}
EOF
)"

echo
echo "  ✅ TEST 4 ZAKOŃCZONY"
echo "  📄 monitoring CSV: ${MONITOR}"
[[ "$PRIMARIES_AFTER" -ge "2" ]] && echo "  ⚠️  Uruchom teraz: ./reset_after_splitbrain.sh"
