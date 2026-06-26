#!/usr/bin/env bash
# =====================================================================
# Instalacja pakietów WireGuard (wykonywane PO STRONIE VM przez ssh)
# =====================================================================
set -euo pipefail
sudo apt-get update -qq
sudo apt-get install -y wireguard wireguard-tools
echo "[ok] WireGuard zainstalowany: $(wg --version | head -1)"
