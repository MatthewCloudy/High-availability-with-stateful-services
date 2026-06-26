#!/usr/bin/env bash
# =====================================================================
# Krok 1: WireGuard — pełna konfiguracja tunelu VM1 <-> VM2
#
# Co robi:
#  1. Instaluje wireguard-tools na obu VM-kach
#  2. Generuje pary kluczy na obu
#  3. Pobiera klucze publiczne na Maca
#  4. Generuje /etc/wireguard/wg0.conf na każdej VM:
#       - VM1: ListenPort + peer VM2
#       - VM2: Endpoint=VM1 + peer VM1
#  5. Włącza i startuje wg-quick@wg0 (z autostartem przy boocie)
#  6. Testuje ping przez tunel w obie strony
#
# Adresacja tunelu (z config.sh): VM1=10.0.0.1, VM2=10.0.0.2
# Uruchamiać NA MACU.
# =====================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../config.sh"

echo "=== 1/5 Instalacja pakietów ==="
ssh_vm1 'bash -s' < "${SCRIPT_DIR}/install.sh"
ssh_vm2 'bash -s' < "${SCRIPT_DIR}/install.sh"

echo ""
echo "=== 2/5 Generowanie kluczy ==="
VM1_KEYS=$(ssh_vm1 'bash -s' < "${SCRIPT_DIR}/genkeys.sh")
VM2_KEYS=$(ssh_vm2 'bash -s' < "${SCRIPT_DIR}/genkeys.sh")
VM1_PRIV=$(echo "$VM1_KEYS" | grep '^PRIV=' | cut -d= -f2-)
VM1_PUB=$(echo  "$VM1_KEYS" | grep '^PUB='  | cut -d= -f2-)
VM2_PRIV=$(echo "$VM2_KEYS" | grep '^PRIV=' | cut -d= -f2-)
VM2_PUB=$(echo  "$VM2_KEYS" | grep '^PUB='  | cut -d= -f2-)
echo "  VM1 PUB: ${VM1_PUB}"
echo "  VM2 PUB: ${VM2_PUB}"

echo ""
echo "=== 3/5 Konfiguracja VM1 (nasłuchuje) ==="
ssh_vm1 "sudo tee /etc/wireguard/wg0.conf > /dev/null <<EOF
[Interface]
Address = ${VM1_WG}/${WG_SUBNET_MASK}
ListenPort = ${WG_PORT}
PrivateKey = ${VM1_PRIV}

[Peer]
# VM2
PublicKey = ${VM2_PUB}
AllowedIPs = ${VM2_WG}/32
PersistentKeepalive = 25
EOF
sudo chmod 600 /etc/wireguard/wg0.conf"

echo "=== 4/5 Konfiguracja VM2 (klient, łączy się z VM1) ==="
ssh_vm2 "sudo tee /etc/wireguard/wg0.conf > /dev/null <<EOF
[Interface]
Address = ${VM2_WG}/${WG_SUBNET_MASK}
PrivateKey = ${VM2_PRIV}

[Peer]
# VM1
PublicKey = ${VM1_PUB}
Endpoint = ${VM1_LAN}:${WG_PORT}
AllowedIPs = ${VM1_WG}/32
PersistentKeepalive = 25
EOF
sudo chmod 600 /etc/wireguard/wg0.conf"

echo ""
echo "=== 5/5 Start tunelu + autostart ==="
ssh_vm1 'sudo systemctl enable --now wg-quick@wg0'
ssh_vm2 'sudo systemctl enable --now wg-quick@wg0'

sleep 3
echo ""
echo "=== Weryfikacja: ping przez tunel ==="
ssh_vm1 "ping -c 3 -W 2 ${VM2_WG}"
echo "---"
ssh_vm2 "ping -c 3 -W 2 ${VM1_WG}"

echo ""
echo "[DONE] WireGuard skonfigurowany. Status:"
ssh_vm1 'sudo wg show'
