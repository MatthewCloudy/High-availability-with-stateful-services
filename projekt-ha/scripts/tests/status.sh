#!/usr/bin/env bash
# =====================================================================
# Szybki przegląd stanu klastra przed/po teście.
# Nie wymaga uprawnień — tylko czyta.
# =====================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

h1 "STAN KLASTRA"

h2 "Pacemaker"
ssh_vm1 'sudo pcs status 2>/dev/null' | tail -18 | sed 's/^/  /'

h2 "DRBD"
drbd_brief

h2 "WireGuard"
ssh_vm1 'sudo wg show 2>/dev/null' | sed 's/^/  vm1: /'
ssh_vm2 'sudo wg show 2>/dev/null' 2>/dev/null | sed 's/^/  vm2: /' || echo "  (vm2 nieosiągalna)"

h2 "Tailscale"
ssh_vm1 'sudo tailscale status 2>/dev/null' | sed 's/^/  /'

h2 "VIP /health"
HEALTH=$(ping_vip)
echo "  $HEALTH"

h2 "Ping VM1 → VM2 (przez tunel WG)"
ssh_vm1 "ping -c 2 -W 2 ${VM2_WG} 2>&1 | tail -3" | sed 's/^/  /'
