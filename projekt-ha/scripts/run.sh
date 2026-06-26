#!/usr/bin/env bash
# =====================================================================
# Master orchestrator — odpala wszystkie kroki od zera.
# Zakłada że VM1 i VM2 są już uruchomione, mają zainstalowany Ubuntu
# z openssh-server i są dostępne pod adresami z config.sh.
#
# Uruchamianie:
#   ./run.sh           - wszystko (bootstrap + WG + DRBD)
#   ./run.sh wg        - tylko WireGuard
#   ./run.sh drbd      - tylko DRBD
#   ./run.sh test      - test failover
#   ./run.sh status    - stan obu VM
# =====================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

case "${1:-all}" in
    all)
        ./00_ssh_bootstrap.sh
        ./wireguard/setup.sh
        ./drbd/setup.sh
        ./drbd/failover_test.sh
        ./status.sh
        ;;
    ssh)
        ./00_ssh_bootstrap.sh
        ;;
    wg|wireguard)
        ./wireguard/setup.sh
        ;;
    drbd)
        ./drbd/setup.sh
        ;;
    test|failover)
        ./drbd/failover_test.sh
        ;;
    status)
        ./status.sh
        ;;
    *)
        echo "Użycie: $0 [all|ssh|wg|drbd|test|status]"
        exit 1
        ;;
esac
