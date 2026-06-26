#!/usr/bin/env bash
# =====================================================================
# Instalacja DRBD + załadowanie modułu kernela
# Wykonywane PO STRONIE VM.
# =====================================================================
set -euo pipefail
sudo apt-get install -y drbd-utils
sudo modprobe drbd
echo drbd | sudo tee /etc/modules-load.d/drbd.conf > /dev/null
echo "[ok] drbd-utils: $(drbdadm --version | grep DRBDADM_BUILDTAG | head -1)"
echo "[ok] moduł kernela: $(cat /sys/module/drbd/version)"
