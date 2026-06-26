#!/usr/bin/env bash
# =====================================================================
# Awaryjne przywrócenie klastra po split-brainie.
#
# Co robi (DESTRUCTIVE — wymaga potwierdzenia):
#   1. Zatrzymuje klaster (pcs cluster stop --all)
#   2. Na VM2: drbdadm down → wipe-md → create-md → up
#      (VM2 będzie SyncTarget, dane LOKALNE na vm2 ZNIKNĄ)
#   3. Na VM1: drbdadm down → up → primary --force
#      (VM1 zostaje źródłem prawdy — jego dane są zachowane)
#   4. Sync VM1 → VM2 startuje
#   5. Start klastra
#
# UŻYTECZNE PO:
#   - test4_vpn_break.sh (gdy wystąpił split-brain)
#   - ręcznym zatrzymaniu DRBD na jednym węźle
#   - widzeniu "StandAlone" w drbdadm status
#
# WAŻNE: zakłada że dane na VM1 są nowsze / prawidłowe.
#        Jeśli chcesz odwrotnie, zamień zmienne SRC/DST na początku.
# =====================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

SRC="vm1"      # źródło prawdy (te dane zostają)
DST="vm2"     # tu będzie wipe-md

h1 "RESET KLASTRA PO SPLIT-BRAINIE"
echo
echo "  Plan:"
echo "    Źródło prawdy:  ${SRC}  (dane zachowane)"
echo "    Wipe-md:        ${DST}  (DANE LOKALNE ZNIKNĄ — zostaną nadpisane z ${SRC})"
echo
echo "  Czas wykonania: ~2-15 min (zależnie od ilości danych do zsynchronizowania"
echo "                  i przepustowości łącza WAN — przez tunel WG/TS)."
echo

read -r -p "  Kontynuować? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Anulowano."; exit 0; }

T0=$(date +%s)

h2 "[1/6] Zatrzymanie klastra"
ssh_vm1 'sudo pcs cluster stop --all 2>&1' | sed 's/^/  /'
sleep 5

h2 "[2/6] DRBD down na obu (na siłę odmontuj /data)"
ssh_vm1 'sudo umount /data 2>/dev/null; sudo drbdadm down r0 2>&1 || true' | sed 's/^/  /'
ssh_vm2 'sudo umount /data 2>/dev/null; sudo drbdadm down r0 2>&1 || true' | sed 's/^/  /'

h2 "[3/6] Wipe metadata na ${DST} (DESTRUCTIVE)"
ssh_vm2 'sudo drbdadm --force wipe-md r0 2>&1 || true; sudo drbdadm --force create-md r0 2>&1' | sed 's/^/  /'

h2 "[4/6] DRBD up na obu + force Primary na ${SRC}"
ssh_vm1 'sudo drbdadm up r0' | sed 's/^/  /'
ssh_vm2 'sudo drbdadm up r0' | sed 's/^/  /'
sleep 3
ssh_vm1 'sudo drbdadm primary --force r0' | sed 's/^/  /'

h2 "[5/6] Obserwacja synchronizacji ${SRC} → ${DST}"
for i in $(seq 1 6); do
    sleep 10
    DT=$(( $(date +%s) - T0 ))
    DONE=$(ssh_vm1 'sudo drbdadm status r0 2>&1 | grep -oE "done:[0-9.]+" | head -1' || echo "")
    REPL=$(ssh_vm1 'sudo drbdadm status r0 2>&1 | grep -oE "replication:[A-Za-z]+" | head -1' || echo "")
    echo "  [t=${DT}s] ${REPL} ${DONE}"
done

h2 "[6/6] Start klastra"
ssh_vm1 'sudo pcs cluster start --all 2>&1' | sed 's/^/  /'
sleep 15
ssh_vm1 'sudo pcs resource cleanup 2>&1 | tail -3' | sed 's/^/  /'
sleep 10

h2 "STAN KOŃCOWY"
ssh_vm1 'sudo pcs status' | tail -12 | sed 's/^/  /'
echo
echo "  DRBD vm1:"
ssh_vm1 'sudo drbdadm status r0' | sed 's/^/    /'

echo
echo "  ℹ️  UWAGA: synchronizacja może trwać dalej w tle (jeśli dużo danych)."
echo "       Sprawdź postęp komendą:  ssh ${SSH_USER}@${VM1_LAN} 'sudo drbdadm status r0'"
echo
echo "  ✅ RESET ZAKOŃCZONY (klaster online, sync może lecieć w tle)"
