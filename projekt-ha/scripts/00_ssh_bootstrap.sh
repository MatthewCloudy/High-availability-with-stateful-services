#!/usr/bin/env bash
# =====================================================================
# Krok 0: bootstrap SSH
#   - generuje klucz ed25519 na Macu (jeśli go nie ma)
#   - wgrywa publiczny klucz na VM1 i VM2
#   - włącza sudo NOPASSWD dla użytkownika filip na obu VM-kach
# Po tym skrypcie reszta kroków leci bez interakcji z hasłem.
#
# Wymaga: zainstalowanego `expect` na Macu (jest natywnie w macOS).
# Uruchamiać NA MACU.
# =====================================================================
set -euo pipefail
source "$(dirname "$0")/config.sh"

# 1. Wygeneruj klucz ed25519 jeśli nie istnieje
if [[ ! -f ~/.ssh/id_ed25519 ]]; then
    echo "[i] Generuję klucz SSH..."
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N '' -C "$(whoami)@$(hostname -s)"
else
    echo "[ok] Klucz SSH już istnieje"
fi

# 2. Wgraj klucz na obie VM-ki przez ssh-copy-id z hasłem podawanym przez expect
copy_key_to() {
    local host="$1"
    echo "[i] Wgrywam klucz na ${SSH_USER}@${host}..."
    /usr/bin/expect <<EOF
set timeout 20
spawn ssh-copy-id -o StrictHostKeyChecking=accept-new ${SSH_USER}@${host}
expect {
    "assword:" { send "${SSH_PASS}\r"; exp_continue }
    eof
}
EOF
}
copy_key_to "$VM1_LAN"
copy_key_to "$VM2_LAN"

# 3. NOPASSWD sudo (przyspiesza dalsze skrypty)
setup_nopasswd() {
    local host="$1"
    echo "[i] Konfiguruję NOPASSWD na ${host}..."
    ssh "${SSH_USER}@${host}" "echo '${SSH_PASS}' | sudo -S bash -c '
        echo \"${SSH_USER} ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/${SSH_USER}-nopasswd
        chmod 0440 /etc/sudoers.d/${SSH_USER}-nopasswd
    '"
}
setup_nopasswd "$VM1_LAN"
setup_nopasswd "$VM2_LAN"

# 4. Weryfikacja
ssh_vm1 'sudo -n true && echo "[ok] VM1 sudo NOPASSWD"'
ssh_vm2 'sudo -n true && echo "[ok] VM2 sudo NOPASSWD"'
echo "[DONE] Bootstrap zakończony"
