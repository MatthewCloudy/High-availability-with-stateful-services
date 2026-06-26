#!/usr/bin/env bash
# =====================================================================
# Generowanie pary kluczy WireGuard w /etc/wireguard
# Idempotentne: jeśli klucze są, nie nadpisuje.
# Wykonywane PO STRONIE VM.
# =====================================================================
set -euo pipefail
sudo install -d -m 700 /etc/wireguard
if [[ ! -f /etc/wireguard/privatekey ]]; then
    sudo bash -c '
        cd /etc/wireguard
        umask 077
        wg genkey | tee privatekey | wg pubkey > publickey
    '
fi
echo "PRIV=$(sudo cat /etc/wireguard/privatekey)"
echo "PUB=$(sudo cat /etc/wireguard/publickey)"
