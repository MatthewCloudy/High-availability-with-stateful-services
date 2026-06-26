#!/usr/bin/env bash
# =====================================================================
# TEST 5 (z koncepcji, sekcja 2.5.5) — awaria podczas uploadu
#
# Co robi:
#   1. Generuje DUŻY plik (domyślnie 20 MB — przesyłanie ~30 s przez WAN)
#   2. Zaczyna upload na VIP (Primary)
#   3. W połowie uploadu wymusza standby aktualnego Primary
#   4. Po failoverze sprawdza:
#        a) czy curl zakończył się sukcesem czy błędem
#        b) czy plik jest dostępny po failoverze
#        c) jeśli tak — porównuje SHA256
#
# Cel: udowodnić że atomic write w aplikacji (zapis do .tmp + fsync +
# rename) chroni przed niespójnym plikiem (nigdy nie zobaczymy
# częściowego pliku — albo cały, albo żadnego).
#
# Użycie:
#   ./test5_upload_during_fail.sh        # 20 MB, failover w t=8s
#   ./test5_upload_during_fail.sh 50 10  # 50 MB, failover w t=10s
# =====================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

SIZE_MB="${1:-20}"
WHEN_KILL_S="${2:-8}"

h1 "TEST 5 — Awaria w trakcie uploadu (${SIZE_MB} MB, kill po ${WHEN_KILL_S}s)"

require_healthy_cluster
PRIMARY=$(current_primary)
OTHER=$([ "$PRIMARY" == "vm1" ] && echo vm2 || echo vm1)

# Generuj
h2 "Setup: plik ${SIZE_MB} MB"
TMP=$(mktemp)
dd if=/dev/urandom of="$TMP" bs=1M count="$SIZE_MB" 2>/dev/null
SHA_PRE=$(shasum -a 256 "$TMP" | awk '{print $1}')
SIZE_B=$(wc -c < "$TMP" | tr -d ' ')
NAME="t5_${RUN_TS}.bin"
echo "  Plik:      ${TMP} (${SIZE_B} B)"
echo "  SHA256:    ${SHA_PRE}"
echo "  Nazwa:     ${NAME}"

# Wgraj na vm1 (skąd będziemy POST-ować)
scp -q "$TMP" "${SSH_USER}@${VM1_LAN}:/tmp/${NAME}"

# Start upload w tle
h2 "Start uploadu w tle"
UPLOAD_LOG="${RESULTS_DIR}/${RUN_TS}_test5_upload.log"
ssh_vm1 "curl -s --max-time 300 -X POST --data-binary @/tmp/${NAME} \
    -w 'HTTP=%{http_code} time=%{time_total}s spd=%{speed_upload}B/s\n' \
    'http://${VIP}:${APP_PORT}/upload?name=${NAME}'" > "$UPLOAD_LOG" 2>&1 &
CURL_PID=$!
T0=$(date +%s)
echo "  PID curl (lokalny ssh): ${CURL_PID}"

# Po WHEN_KILL_S sekundach wymuszamy failover
sleep "$WHEN_KILL_S"
echo
echo "  >>> [t=${WHEN_KILL_S}s] WYMUSZAM AWARIĘ: standby ${PRIMARY}"
ssh_vm1 "sudo pcs node standby ${PRIMARY}"

# Czekamy aż curl skończy (sukcesem lub porażką)
echo "  ... czekam aż curl skończy ..."
wait $CURL_PID 2>/dev/null || true
T1=$(date +%s)

UPLOAD_RESULT=$(cat "$UPLOAD_LOG")
echo
echo "  Wynik uploadu (po $((T1 - T0))s):"
echo "$UPLOAD_RESULT" | sed 's/^/    /'

# Czekamy aż failover się zakończy
echo
echo "  Czekam aż ${OTHER} przejmie..."
for i in $(seq 1 36); do
    sleep 5
    CUR=$(current_primary 2>/dev/null || echo "")
    [[ "$CUR" == "$OTHER" ]] && { echo "  ✅ Po $((i*5))s — ${OTHER} jest Primary"; break; }
done

sleep 5
NEW_PRIMARY=$(current_primary)

# Sprawdź czy plik istnieje
h2 "Diagnoza pliku na nowym Primary (${NEW_PRIMARY})"
FILE_LIST=$(ssh_vm1 "curl -s --max-time 5 'http://${VIP}:${APP_PORT}/'")
echo "  Lista plików: $FILE_LIST"

FILE_PRESENT="NIE"
if echo "$FILE_LIST" | grep -q "\"${NAME}\""; then
    FILE_PRESENT="TAK"
fi

SHA_POST="(nieobliczone)"
RESULT="POMYŚLNE (plik niepełny lub brak)"
if [[ "$FILE_PRESENT" == "TAK" ]]; then
    h2 "Pobieram plik z nowego Primary i sprawdzam SHA256"
    TMP2=$(mktemp)
    ssh_vm1 "curl -s --max-time 120 'http://${VIP}:${APP_PORT}/files/${NAME}' -o /tmp/${NAME}_post && cat /tmp/${NAME}_post" > "$TMP2"
    SHA_POST=$(shasum -a 256 "$TMP2" | awk '{print $1}')
    SIZE_POST=$(wc -c < "$TMP2" | tr -d ' ')
    echo "  Rozmiar po:  ${SIZE_POST} B (oryginał: ${SIZE_B} B)"
    echo "  SHA256 pre:  ${SHA_PRE}"
    echo "  SHA256 post: ${SHA_POST}"
    if [[ "$SHA_PRE" == "$SHA_POST" ]]; then
        RESULT="✅ PEŁNY plik się replikował przed awarią (rzadkie — szczęście timingu)"
    else
        RESULT="⚠️ NIESPÓJNY plik (atomic write zawiódł — patrz logi DRBD)"
    fi
    rm -f "$TMP2"
fi

if [[ "$FILE_PRESENT" == "NIE" ]]; then
    RESULT="✅ PRAWIDŁOWO: pliku nie ma (atomic write zadziałał — rename nie nastąpił przed awarią)"
fi

h2 "WYNIKI"
echo "  Wynik uploadu (curl)        : $(echo "$UPLOAD_RESULT" | tail -1)"
echo "  Plik na nowym Primary       : ${FILE_PRESENT}"
echo "  Werdykt                     : ${RESULT}"

# Tabela do sprawozdania
h2 "TABELA DO SPRAWOZDANIA (skopiuj)"
cat <<EOF
| Metryka                                | Wartość                          |
|----------------------------------------|----------------------------------|
| Rozmiar przesyłanego pliku             | ${SIZE_B} B (${SIZE_MB} MB)     |
| Moment wymuszenia awarii               | t=${WHEN_KILL_S} s              |
| Status curl uploadu                    | $(echo "$UPLOAD_RESULT" | grep -oE 'HTTP=[0-9]*' | head -1) |
| Plik dostępny po failoverze            | ${FILE_PRESENT}                  |
| SHA256 zgodne (jeśli plik jest)        | $([ "$SHA_PRE" == "$SHA_POST" ] && echo TAK || echo NIE) |
| Werdykt                                | ${RESULT}                        |
EOF
echo
echo "  ️ℹ️  Mechanizm ochrony w aplikacji:"
echo "      zapis idzie do /data/uploads/.NAZWA.XXX.part (ukryty plik tymczasowy)"
echo "      → fsync(file) + fsync(directory) → rename() do finalnej nazwy"
echo "      Skutek: w widocznym katalogu albo PEŁNY plik, albo nic"

# Cleanup
ssh_vm1 "rm -f /tmp/${NAME} /tmp/${NAME}_post" 2>/dev/null
rm -f "$TMP"
restore_cluster

echo
echo "  ✅ TEST 5 ZAKOŃCZONY"
