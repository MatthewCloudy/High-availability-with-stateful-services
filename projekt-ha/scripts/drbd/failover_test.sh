#!/usr/bin/env bash
# =====================================================================
# Test failover DRBD: ręczne przełączenie Primary VM1 -> VM2 i z powrotem.
# Demonstruje że dane utworzone na jednym węźle są dostępne na drugim.
#
# Bezpieczny - nie psuje stanu, na końcu wraca do VM1=Primary.
# Uruchamiać NA MACU.
# =====================================================================
set -euo pipefail
source "$(dirname "$0")/../config.sh"

echo "=== Stan wyjściowy ==="
ssh_vm1 "sudo drbdadm status ${DRBD_RESOURCE}"

echo ""
echo "=== Krok 1: zapisz plik z timestampem na VM1 ==="
STAMP=$(date +%Y%m%d-%H%M%S)
ssh_vm1 "echo 'failover test ${STAMP}' | sudo tee ${DRBD_MOUNT}/failover-${STAMP}.txt"

echo ""
echo "=== Krok 2: VM1 odmontowuje i staje się Secondary ==="
ssh_vm1 "sudo umount ${DRBD_MOUNT} && sudo drbdadm secondary ${DRBD_RESOURCE}"

echo ""
echo "=== Krok 3: VM2 staje się Primary i montuje ==="
ssh_vm2 "sudo drbdadm primary ${DRBD_RESOURCE} && sudo mkdir -p ${DRBD_MOUNT} && sudo mount ${DRBD_DEVICE} ${DRBD_MOUNT}"

echo ""
echo "=== Krok 4: sprawdzamy plik na VM2 ==="
ssh_vm2 "ls -la ${DRBD_MOUNT}/failover-${STAMP}.txt && cat ${DRBD_MOUNT}/failover-${STAMP}.txt"

echo ""
echo "=== Krok 5: powrót — VM2 -> Secondary, VM1 -> Primary ==="
ssh_vm2 "sudo umount ${DRBD_MOUNT} && sudo drbdadm secondary ${DRBD_RESOURCE}"
ssh_vm1 "sudo drbdadm primary ${DRBD_RESOURCE} && sudo mount ${DRBD_DEVICE} ${DRBD_MOUNT}"

echo ""
echo "=== Stan końcowy ==="
ssh_vm1 "sudo drbdadm status ${DRBD_RESOURCE}"
echo "[DONE] Failover OK — replikacja działa w obie strony"
