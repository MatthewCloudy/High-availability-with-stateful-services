#!/usr/bin/env bash
# =====================================================================
# TEST 2 (z koncepcji, sekcja 2.5.2) — zachowanie danych po failover
#
# Co robi:
#   1. Generuje plik testowy (domyślnie 2 MB)
#   2. Liczy SHA256 lokalnie
#   3. Wgrywa go przez VIP na aktualny Primary
#   4. Robi standby aktualnego Primary (failover na drugi węzeł)
#   5. Czeka aż Pacemaker przeniesie zasoby (max 180 s)
#   6. Pobiera plik przez VIP z nowego Primary i liczy SHA256
#   7. Porównuje SHA256 pre/post — to dowód że DRBD zreplikował bit-w-bit
#
# Użycie:
#   ./test2_integrity.sh             # plik 2 MB
#   ./test2_integrity.sh 10          # plik 10 MB
# =====================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

SIZE_MB="${1:-2}"
h1 "TEST 2 — Zachowanie danych po failover (${SIZE_MB} MB)"

require_healthy_cluster
PRIMARY=$(current_primary)
OTHER=$([ "$PRIMARY" == "vm1" ] && echo vm2 || echo vm1)

# Generuj plik
h2 "Setup: generowanie pliku testowego"
TMP=$(mktemp)
dd if=/dev/urandom of="$TMP" bs=1M count="$SIZE_MB" 2>/dev/null
SHA_PRE=$(shasum -a 256 "$TMP" | awk '{print $1}')
SIZE_B=$(wc -c < "$TMP" | tr -d ' ')
NAME="t2_${RUN_TS}.bin"
echo "  Plik:   ${TMP}"
echo "  Rozmiar: ${SIZE_B} B"
echo "  SHA256:  ${SHA_PRE}"
echo "  Nazwa na serwerze: ${NAME}"

# Upload
h2 "Upload na Primary (${PRIMARY}) przez VIP"
scp -q "$TMP" "${SSH_USER}@${VM1_LAN}:/tmp/${NAME}"
RESP=$(ssh_vm1 "curl -s -X POST --data-binary @/tmp/${NAME} 'http://${VIP}:${APP_PORT}/upload?name=${NAME}'")
echo "  Odpowiedź serwera: $RESP"
SHA_UPLOADED=$(echo "$RESP" | grep -oE '"sha256": *"[^"]*"' | cut -d'"' -f4)
if [[ "$SHA_PRE" == "$SHA_UPLOADED" ]]; then
    echo "  ✅ SHA256 uploadu zgodne z lokalnym"
else
    echo "  ❌ SHA256 uploadu NIE zgodne!"
    exit 1
fi

# Wymuszamy failover
h2 "Failover: standby ${PRIMARY}"
ssh_vm1 "sudo pcs node standby ${PRIMARY}"
T0=$(date +%s)

# Czekamy aż zasoby przelecą (max 180s)
echo "  Czekam aż zasoby przeniosą się na ${OTHER}..."
SUCCESS=0
for i in $(seq 1 36); do  # 36 x 5s = 180s max
    sleep 5
    CUR=$(current_primary 2>/dev/null || echo "")
    if [[ "$CUR" == "$OTHER" ]]; then
        T1=$(date +%s)
        echo "  ✅ Po $((T1 - T0))s — zasoby na ${OTHER}"
        SUCCESS=1
        break
    fi
done
if [[ $SUCCESS -eq 0 ]]; then
    echo "  ❌ Failover nie zakończony w 180s. Stan klastra:"
    cluster_brief
    restore_cluster
    exit 1
fi

# Krótka stabilizacja
sleep 5

# Pobranie
h2 "Pobranie pliku przez VIP (powinien przyjść z ${OTHER})"
TMP2=$(mktemp)
HTTP=$(ssh_vm1 "curl -s --max-time 60 'http://${VIP}:${APP_PORT}/files/${NAME}' -o /tmp/${NAME}_post -w '%{http_code} %{size_download}'")
echo "  Curl: $HTTP"
ssh_vm1 "cat /tmp/${NAME}_post" > "$TMP2"
SHA_POST=$(shasum -a 256 "$TMP2" | awk '{print $1}')

h2 "WYNIKI"
echo "  SHA256 pre  = ${SHA_PRE}"
echo "  SHA256 post = ${SHA_POST}"
if [[ "$SHA_PRE" == "$SHA_POST" ]]; then
    echo "  ✅ INTEGRALNOŚĆ ZACHOWANA — plik bit-w-bit identyczny po failoverze"
    RESULT="PASS"
else
    echo "  ❌ INTEGRALNOŚĆ NARUSZONA — SHA256 różne!"
    RESULT="FAIL"
fi

# Cleanup
ssh_vm1 "rm -f /tmp/${NAME} /tmp/${NAME}_post" 2>/dev/null
rm -f "$TMP" "$TMP2"
restore_cluster

# Tabela do sprawozdania
h2 "TABELA DO SPRAWOZDANIA (skopiuj)"
cat <<EOF
| Metryka                          | Wartość                              |
|----------------------------------|--------------------------------------|
| Rozmiar pliku testowego          | ${SIZE_B} B (${SIZE_MB} MB)          |
| SHA256 przed failoverem          | ${SHA_PRE}                           |
| SHA256 po failoverze             | ${SHA_POST}                          |
| Integralność danych              | ${RESULT}                            |
| Replikacja przez                 | DRBD protocol C (synchroniczna)      |
EOF

save_result "test2_metrics" "$(cat <<EOF
size_b=${SIZE_B}
sha_pre=${SHA_PRE}
sha_post=${SHA_POST}
result=${RESULT}
EOF
)"
echo
echo "  ✅ TEST 2 ZAKOŃCZONY"
