#!/usr/bin/env bash
# =====================================================================
# Szybki przegląd stanu obu VM-ek: WireGuard + DRBD + ping + mount
# Wygodne do wklejania w sprawozdaniu / przy debug'u.
# =====================================================================
set -euo pipefail
source "$(dirname "$0")/config.sh"

echo "========== VM1 (${VM1_LAN}, wg=${VM1_WG}) =========="
ssh_vm1 'echo "hostname  : $(hostname)"
echo "uptime    : $(uptime -p)"
echo ""
echo "--- WireGuard ---"
sudo wg show
echo ""
echo "--- DRBD ---"
sudo drbdadm status '"${DRBD_RESOURCE}"' 2>/dev/null || echo "DRBD nie działa"
echo ""
echo "--- mount /data ---"
mount | grep '"${DRBD_MOUNT}"' || echo "/data nie zamontowane"
echo ""'

echo ""
echo "========== VM2 (${VM2_LAN}, wg=${VM2_WG}) =========="
ssh_vm2 'echo "hostname  : $(hostname)"
echo "uptime    : $(uptime -p)"
echo ""
echo "--- WireGuard ---"
sudo wg show
echo ""
echo "--- DRBD ---"
sudo drbdadm status '"${DRBD_RESOURCE}"' 2>/dev/null || echo "DRBD nie działa"
echo ""
echo "--- mount /data ---"
mount | grep '"${DRBD_MOUNT}"' || echo "/data nie zamontowane"
echo ""'

echo ""
echo "========== Ping przez tunel =========="
ssh_vm1 "ping -c 2 -W 2 ${VM2_WG} | tail -2"
