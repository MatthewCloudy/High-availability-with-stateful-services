# Skrypty projektu HA — WireGuard + DRBD

Zestaw skryptów odtwarzających od zera konfigurację wykonaną podczas labu.
Skrypty są **idempotentne** w granicach możliwości — można je uruchamiać wielokrotnie.

## Struktura

```
scripts/
├── config.sh              # zmienne globalne (IP, użytkownik, ścieżki dysków)
├── 00_ssh_bootstrap.sh    # klucz SSH + NOPASSWD sudo na obu VM
├── wireguard/
│   ├── install.sh         # apt install (uruchamiane na VM przez ssh)
│   ├── genkeys.sh         # generowanie pary kluczy WG (na VM)
│   └── setup.sh           # FULL: instalacja + klucze + konfig + start
├── drbd/
│   ├── install.sh         # apt install + modprobe (na VM)
│   ├── setup.sh           # FULL: konfig r0.res + create-md + sync + mkfs + mount
│   └── failover_test.sh   # test ręcznego przełączenia Primary
├── status.sh              # przegląd stanu (WG + DRBD + mount + ping)
└── run.sh                 # orchestrator: ./run.sh all|wg|drbd|test|status
```

## Wymagania wstępne

1. **VM1** (Mac, UTM, Ubuntu Server ARM64) i **VM2** (Windows, VirtualBox, Ubuntu Server x86_64)
   - sieć: **Bridged** — obie w jednej LAN
   - hostnames: `vm1` i `vm2` (sprawdzane przez DRBD)
   - drugi dysk surowy, bez partycji: `/dev/vdb` na VM1, `/dev/sdb` na VM2
   - `openssh-server` zainstalowany przy instalacji
   - użytkownik `filip` z hasłem `12345` (do zmiany w `config.sh`)

2. **Mac (host)**:
   - macOS z `expect` (jest natywnie)
   - możliwość ssh do obu VM po IP z LAN

3. **Aktualne adresy** w `config.sh`:
   - VM1: `192.168.0.122` (LAN), `10.0.0.1` (wg0)
   - VM2: `192.168.0.10`  (LAN), `10.0.0.2` (wg0)
   - jeśli DHCP nadał inne — zmień w `config.sh`

## Użycie

```bash
chmod +x run.sh */*.sh *.sh

# wszystko od zera
./run.sh all

# tylko poszczególne kroki
./run.sh ssh        # klucz + NOPASSWD
./run.sh wg         # WireGuard
./run.sh drbd       # DRBD
./run.sh test       # test failover
./run.sh status     # przegląd stanu
```

## Co robi każdy krok

### 0. `00_ssh_bootstrap.sh`
- Generuje `~/.ssh/id_ed25519` na Macu (jeśli nie ma)
- `ssh-copy-id` na VM1 i VM2 (hasło z `config.sh` przez expect)
- Tworzy `/etc/sudoers.d/filip-nopasswd` na obu

### 1. `wireguard/setup.sh`
- `apt install wireguard wireguard-tools` na obu
- `wg genkey` na każdej, pobranie kluczy publicznych
- `/etc/wireguard/wg0.conf`:
  - **VM1**: `Address=10.0.0.1/24`, `ListenPort=51820`, peer=VM2
  - **VM2**: `Address=10.0.0.2/24`, peer=VM1 z `Endpoint=192.168.0.122:51820`
  - `PersistentKeepalive=25` — utrzymuje NAT (na wszelki wypadek)
- `systemctl enable --now wg-quick@wg0` — autostart przy boocie
- Ping `10.0.0.1 ↔ 10.0.0.2` jako weryfikacja

### 2. `drbd/setup.sh`
- `apt install drbd-utils` + `modprobe drbd` + `/etc/modules-load.d/drbd.conf`
- Generuje `/etc/drbd.d/r0.res` opisujący zasób `r0`:
  - `protocol C` (synchroniczny)
  - `on vm1` → `/dev/vdb`, adres `10.0.0.1:7788`
  - `on vm2` → `/dev/sdb`, adres `10.0.0.2:7788`
  - `meta-disk internal` (metadane w końcówce dysku)
  - timeouty zwiększone pod WiFi/VPN
- `drbdadm create-md r0` (nadpisuje pierwsze sektory dysku!)
- `drbdadm up r0` (oba w `Secondary/Inconsistent`)
- `drbdadm primary --force r0` na VM1 → pierwsza synchronizacja
- `mkfs.ext4 /dev/drbd0` + `mount /dev/drbd0 /data`
- Zapisuje testowy plik `/data/hello.txt`

### 3. `drbd/failover_test.sh`
- Tworzy plik z timestampem na VM1
- `umount` + `drbdadm secondary` na VM1
- `drbdadm primary` + `mount` na VM2
- `cat` pliku na VM2 (powinien być identyczny)
- Powrót — VM1 znów Primary

## Co po DRBD

To jest **fundament HA**. Brakuje jeszcze:

1. **Pacemaker + Corosync** — automatyczny failover (zamiast ręcznego `drbdadm primary`).
2. **VIP** — wirtualny adres `10.0.0.100` migrujący między VM.
3. **Aplikacja HTTP** — `/upload`, `/files/<n>`, `/health`.
4. **Testy z koncepcji projektu**: awaria węzła, awaria w trakcie uploadu, split-brain, resync po powrocie.

## Najczęstsze problemy

| Objaw | Przyczyna | Lek |
|---|---|---|
| `drbdadm create-md`: "Device size would be truncated" | dysk za mały po metadanych | dysk ≥ 100 MB |
| DRBD `WFConnection` przez długi czas | firewall, zły IP w `r0.res`, brak tunelu WG | sprawdź `wg show`, `ss -tlnp \| grep 7788` |
| `Permission denied (publickey)` po reboocie | inne IP DHCP albo wyczyszczone authorized_keys | `./run.sh ssh` ponownie |
| DRBD `SplitBrain` | oba węzły uznały się za Primary | `drbdadm secondary r0` na obu, `drbdadm connect --discard-my-data r0` na "starszym" |

## Komendy diagnostyczne

```bash
# Stan
sudo drbdadm status r0
sudo wg show
sudo systemctl status wg-quick@wg0

# Logi
sudo dmesg | grep -iE 'drbd|wireguard'
sudo journalctl -u wg-quick@wg0 -n 50

# Surowy /proc
cat /proc/drbd
```
