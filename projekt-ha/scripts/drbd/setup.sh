#!/usr/bin/env bash
# =====================================================================
# Krok 2: DRBD — replikacja dysku przez tunel WireGuard
#
# Co robi:
#  1. Instaluje drbd-utils + ładuje moduł kernela na obu VM
#  2. Generuje /etc/drbd.d/r0.res (zasób r0) i wgrywa na obie
#  3. drbdadm create-md r0  (inicjalizacja metadanych na vdb/sdb)
#  4. drbdadm up r0         (start zasobu, oba w stanie Secondary/Inconsistent)
#  5. drbdadm primary --force r0 na VM1 (pierwsza synchronizacja)
#  6. mkfs.ext4 + mount /dev/drbd0 → /data na VM1
#
# WAŻNE:
#  - Hostname VM-ek MUSI być vm1 i vm2 (DRBD pasuje sekcje "on X" po hostname).
#  - Dyski $VM1_DISK i $VM2_DISK są nadpisywane! Mają być gołe (bez partycji).
#  - Replikacja idzie przez tunel: 10.0.0.1:7788 ↔ 10.0.0.2:7788
#
# Uruchamiać NA MACU.
# =====================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../config.sh"

# ---------- sanity check ----------
echo "=== Sanity check ==="
H1=$(ssh_vm1 hostname); [[ "$H1" == "$VM1_HOSTNAME" ]] || { echo "[!] VM1 hostname='$H1' a oczekiwano '$VM1_HOSTNAME'. Zmień: sudo hostnamectl set-hostname $VM1_HOSTNAME"; exit 1; }
H2=$(ssh_vm2 hostname); [[ "$H2" == "$VM2_HOSTNAME" ]] || { echo "[!] VM2 hostname='$H2' a oczekiwano '$VM2_HOSTNAME'. Zmień: sudo hostnamectl set-hostname $VM2_HOSTNAME"; exit 1; }
echo "  hostnames OK ($H1, $H2)"

# ---------- 1. Instalacja ----------
echo ""
echo "=== 1/6 Instalacja drbd-utils ==="
ssh_vm1 'bash -s' < "${SCRIPT_DIR}/install.sh"
ssh_vm2 'bash -s' < "${SCRIPT_DIR}/install.sh"

# ---------- 2. Konfiguracja zasobu ----------
echo ""
echo "=== 2/6 Wgrywanie /etc/drbd.d/r0.res ==="
RES_TMP=$(mktemp)
cat > "$RES_TMP" <<EOF
resource ${DRBD_RESOURCE} {
    protocol C;     # synchroniczny — zapis potwierdzony dopiero po replikacji

    on ${VM1_HOSTNAME} {
        device    ${DRBD_DEVICE};
        disk      ${VM1_DISK};
        address   ${VM1_WG}:${DRBD_PORT};
        meta-disk internal;
    }
    on ${VM2_HOSTNAME} {
        device    ${DRBD_DEVICE};
        disk      ${VM2_DISK};
        address   ${VM2_WG}:${DRBD_PORT};
        meta-disk internal;
    }

    net {
        # zwiększone timeouty pod WiFi/VPN, niech jitter nie zrywa replikacji
        ping-timeout 30;
        connect-int  10;
        ping-int     10;
    }

    disk {
        # adaptacyjna kontrola przepływu - dobrze działa po łączu o zmiennej przepustowości
        c-plan-ahead  10;
        c-fill-target 24M;
        c-max-rate   100M;
        c-min-rate     4M;
    }
}
EOF

scp -q "$RES_TMP" "${SSH_USER}@${VM1_LAN}:/tmp/r0.res"
scp -q "$RES_TMP" "${SSH_USER}@${VM2_LAN}:/tmp/r0.res"
rm "$RES_TMP"
ssh_vm1 "sudo mv /tmp/r0.res /etc/drbd.d/r0.res && sudo chmod 644 /etc/drbd.d/r0.res && sudo drbdadm dump ${DRBD_RESOURCE} > /dev/null && echo VM1_OK"
ssh_vm2 "sudo mv /tmp/r0.res /etc/drbd.d/r0.res && sudo chmod 644 /etc/drbd.d/r0.res && sudo drbdadm dump ${DRBD_RESOURCE} > /dev/null && echo VM2_OK"

# ---------- 3. Inicjalizacja metadanych ----------
echo ""
echo "=== 3/6 create-md (NADPISUJE ${VM1_DISK} na VM1 i ${VM2_DISK} na VM2!) ==="
ssh_vm1 "sudo drbdadm create-md ${DRBD_RESOURCE} || true"
ssh_vm2 "sudo drbdadm create-md ${DRBD_RESOURCE} || true"

# ---------- 4. Start zasobu ----------
echo ""
echo "=== 4/6 drbdadm up ${DRBD_RESOURCE} ==="
ssh_vm1 "sudo drbdadm up ${DRBD_RESOURCE}"
ssh_vm2 "sudo drbdadm up ${DRBD_RESOURCE}"
sleep 12   # czekamy aż peery się zobaczą (connect-int=10)
ssh_vm1 "sudo drbdadm status ${DRBD_RESOURCE}"

# ---------- 5. Promocja VM1 -> Primary ----------
echo ""
echo "=== 5/6 VM1 -> Primary (pierwsza synchronizacja w tle) ==="
ssh_vm1 "sudo drbdadm primary --force ${DRBD_RESOURCE}"
sleep 2
ssh_vm1 "sudo drbdadm status ${DRBD_RESOURCE}"

# ---------- 6. Format ext4 + mount ----------
echo ""
echo "=== 6/6 mkfs.ext4 + mount ${DRBD_DEVICE} → ${DRBD_MOUNT} ==="
ssh_vm1 "sudo mkfs.ext4 -F ${DRBD_DEVICE}"
ssh_vm1 "sudo mkdir -p ${DRBD_MOUNT} && sudo mount ${DRBD_DEVICE} ${DRBD_MOUNT}"
ssh_vm1 "echo 'plik testowy DRBD z VM1' | sudo tee ${DRBD_MOUNT}/hello.txt > /dev/null"

echo ""
echo "[DONE] DRBD skonfigurowany. Status końcowy:"
ssh_vm1 "df -h ${DRBD_MOUNT}; sudo drbdadm status ${DRBD_RESOURCE}"
