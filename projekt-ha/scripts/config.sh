#!/usr/bin/env bash
# =====================================================================
# Wspólna konfiguracja projektu HA (WireGuard + DRBD)
# Źródło prawdy dla wszystkich skryptów - zmień tu zmienne raz.
# =====================================================================

# ---------- Użytkownik i SSH ----------
SSH_USER="filip"
SSH_PASS="12345"           # tylko do pierwszego ssh-copy-id; potem klucz

# ---------- Adresy w LAN (Bridged adapter) ----------
VM1_LAN="192.168.0.122"
VM2_LAN="192.168.0.10"

# ---------- Adresy w tunelu WireGuard ----------
VM1_WG="10.0.0.1"
VM2_WG="10.0.0.2"
WG_SUBNET_MASK="24"
WG_PORT="51820"

# ---------- DRBD ----------
DRBD_RESOURCE="r0"
DRBD_DEVICE="/dev/drbd0"
DRBD_PORT="7788"
VM1_DISK="/dev/vdb"        # UTM/virtio na Macu
VM2_DISK="/dev/sdb"        # VirtualBox/SATA na Windowsie
DRBD_MOUNT="/data"

# ---------- Hostname (DRBD identyfikuje peery po hostname!) ----------
VM1_HOSTNAME="vm1"
VM2_HOSTNAME="vm2"

# ---------- Helper do ssh ----------
ssh_vm1() { ssh -o StrictHostKeyChecking=accept-new "${SSH_USER}@${VM1_LAN}" "$@"; }
ssh_vm2() { ssh -o StrictHostKeyChecking=accept-new "${SSH_USER}@${VM2_LAN}" "$@"; }
