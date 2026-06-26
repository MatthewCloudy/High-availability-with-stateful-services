#!/usr/bin/env bash
# =====================================================================
# Wspólne funkcje używane przez wszystkie skrypty testowe.
# Source-uj na początku każdego testu: source "$(dirname "$0")/lib/common.sh"
# =====================================================================

# Konfiguracja (zgodna z scripts/config.sh)
VM1_LAN="192.168.0.122"
VM1_WG="10.0.0.1"
VM2_WG="10.0.0.2"
VIP="10.0.0.100"
APP_PORT="8080"
SSH_USER="filip"
DRBD_RESOURCE="r0"
DRBD_MOUNT="/data"

# Folder na wyniki
RESULTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results"
mkdir -p "$RESULTS_DIR"

# Timestamp uruchomienia (do nazwy pliku z wynikami)
RUN_TS="$(date +%Y%m%d-%H%M%S)"

# ---------- SSH helpers ----------
ssh_vm1() { ssh "${SSH_USER}@${VM1_LAN}" "$@"; }
# VM2 osiągalna tylko przez tunel WG (przez vm1) — używamy ProxyJump
ssh_vm2() { ssh -A -o ProxyJump="${SSH_USER}@${VM1_LAN}" "${SSH_USER}@${VM2_WG}" "$@"; }

# ---------- Output helpers ----------
hr()   { printf '%.0s=' {1..70}; echo; }
hr2()  { printf '%.0s-' {1..70}; echo; }
h1()   { hr; echo "  $1"; hr; }
h2()   { echo; hr2; echo "  $1"; hr2; }

# Stan klastra zwięźle
cluster_brief() {
    ssh_vm1 'sudo pcs status 2>/dev/null' | grep -E "^\s*\*\s+(Online|OFFLINE|Standby|Promoted|Unpromoted|drbd_fs|vip|fileapp)" | sed 's/^/  /'
}

# Stan DRBD z obu stron
drbd_brief() {
    echo "  --- vm1 ---"
    ssh_vm1 "sudo drbdadm status ${DRBD_RESOURCE} 2>&1" | sed 's/^/  /'
    echo "  --- vm2 ---"
    ssh_vm2 "sudo drbdadm status ${DRBD_RESOURCE} 2>&1" | sed 's/^/  /'
}

# Który węzeł jest aktualnie Primary (zwraca "vm1" lub "vm2")
current_primary() {
    ssh_vm1 'sudo pcs status 2>/dev/null' | grep -A1 'drbd_r0-clone' | grep -oE 'Promoted:\s*\[\s*\w+' | grep -oE 'vm[12]'
}

# Czy VIP odpowiada (timeout 3s)
ping_vip() {
    ssh_vm1 "curl -s --max-time 3 http://${VIP}:${APP_PORT}/health" 2>/dev/null
}

# Zapisz blok do results/ pod kluczem
save_result() {
    local key="$1"
    local content="$2"
    local file="${RESULTS_DIR}/${RUN_TS}_${key}.txt"
    echo "$content" > "$file"
    echo "  📄 zapisano: ${file}"
}

# Sprawdź czy klaster jest "zdrowy" przed startem testu
require_healthy_cluster() {
    h2 "Sanity check klastra przed testem"
    cluster_brief
    drbd_brief
    local prim
    prim=$(current_primary)
    if [[ -z "$prim" ]]; then
        echo
        echo "  ❌ BŁĄD: nie wykryto Primary. Klaster jest niezdrowy."
        echo "     Najpierw uruchom: ./reset_after_splitbrain.sh"
        exit 1
    fi
    local oos
    oos=$(ssh_vm1 "sudo cat /proc/drbd 2>/dev/null | grep -oE 'oos:[0-9]+' | head -1 | cut -d: -f2")
    if [[ -n "$oos" && "$oos" -gt 0 ]]; then
        echo
        echo "  ⚠️  UWAGA: DRBD jeszcze nie zsynchronizowany (oos=${oos} sektorów)."
        echo "     Test się powiedzie, ale wyniki mogą być zaburzone."
        echo "     Sprawdź: ssh ${SSH_USER}@${VM1_LAN} 'sudo drbdadm status ${DRBD_RESOURCE}'"
        read -r -p "  Kontynuować mimo to? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || exit 1
    fi
    echo
    echo "  ✅ Klaster zdrowy. Aktualnie Primary: ${prim}"
}

# Po teście — odzyskaj klaster do stanu wyjściowego (unstandby wszystkich)
restore_cluster() {
    h2 "Przywracanie klastra (unstandby wszystkich)"
    ssh_vm1 'sudo pcs node unstandby vm1 2>&1; sudo pcs node unstandby vm2 2>&1; sudo pcs resource cleanup 2>&1' | grep -vE '^Cleaning|^Waiting|reply' | sed 's/^/  /'
    sleep 5
    cluster_brief
}
