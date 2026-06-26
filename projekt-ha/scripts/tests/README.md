# Scenariusze testów HA — gotowe skrypty

Wykonują testy z **sekcji 2.5 koncepcji projektu** (Plan testów),
zbierają metryki i generują tabelki do wklejenia w sprawozdanie.

## Wymagania wstępne

- Działający klaster (sprawdź: `./status.sh`)
- SSH z Maca do VM1 bez hasła (klucz)
- SSH z Maca do VM2 przez ProxyJump (klucz przekazywany przez vm1)
- Tailscale + WireGuard działają, tunel `10.0.0.0/24` aktywny
- Aplikacja `fileapp` działa pod VIP `10.0.0.100:8080`

## Struktura

```
tests/
├── status.sh                       # przegląd stanu — uruchom przed/po teście
├── test1_failover.sh               # Test 1 — awaria aktywnego węzła
├── test2_integrity.sh              # Test 2 — integralność danych po failoverze
├── test3_recovery.sh               # Test 3 — powrót uszkodzonego węzła
├── test4_vpn_break.sh              # Test 4 — zerwanie VPN (split-brain demo)
├── test5_upload_during_fail.sh     # Test 5 — awaria w trakcie uploadu
├── reset_after_splitbrain.sh       # AWARYJNIE: po Teście 4 lub split-brainie
├── lib/
│   ├── common.sh                   # wspólne funkcje (ssh, formatowanie, sanity)
│   ├── probe.sh                    # sonda HTTP co 0.5s (CSV)
│   └── analyze_probe.sh            # liczy metryki z probe.csv
└── results/                         # wyniki testów (CSV + JSON + tabele)
```

## Użycie

```bash
cd ~/projekt-ha/scripts/tests
chmod +x *.sh lib/*.sh

# Sanity check przed startem:
./status.sh

# Testy z koncepcji (sekcja 2.5):
./test1_failover.sh                   # ~4 min
./test2_integrity.sh                  # ~3 min, plik 2 MB
./test2_integrity.sh 20               # plik 20 MB (opcjonalnie)
./test3_recovery.sh                   # ~5 min
./test4_vpn_break.sh                  # ~2 min, UWAGA: split-brain prawdopodobny
./reset_after_splitbrain.sh           # po Teście 4 (przywrócenie)
./test5_upload_during_fail.sh         # ~5 min, 20 MB
./test5_upload_during_fail.sh 50 10   # 50 MB, kill po 10s
```

## Mapowanie na koncepcję projektu

| Skrypt                          | Sekcja koncepcji                  | Cel                                       |
|---------------------------------|-----------------------------------|-------------------------------------------|
| `test1_failover.sh`             | 2.5.1 awaria aktywnego węzła      | czas niedostępności, klient nie zmienia IP |
| `test2_integrity.sh`            | 2.5.2 zachowanie danych           | SHA256 przed/po — dowód replikacji        |
| `test3_recovery.sh`             | 2.5.3 powrót węzła                | DRBD resync, usługa dostępna w trakcie    |
| `test4_vpn_break.sh`            | 2.5.4 zerwanie VPN                | split-brain w 2-node bez fencingu         |
| `test5_upload_during_fail.sh`   | 2.5.5 awaria w uploadzie          | atomic write — cały plik albo brak        |

Każdy skrypt:
- robi `sanity check` klastra przed testem (zatrzymuje jeśli niezdrowy)
- ma `restore_cluster` na końcu (cofa standby — wraca do stanu wyjściowego)
- generuje **tabelkę markdown** do wklejenia w sprawozdanie
- zapisuje raw dane (CSV, log) w `results/<timestamp>_*` na wypadek
  gdybyś chciał zrobić wykres / własną analizę

## Co skrypty MIERZĄ (do sekcji 2.6 koncepcji)

| Pytanie z koncepcji              | Skąd liczba                                         |
|----------------------------------|-----------------------------------------------------|
| czas przełączenia                | `test1` — analyze_probe → `unavailability_s`        |
| czas niedostępności              | jak wyżej                                           |
| liczba błędnych żądań            | `test1` — analyze_probe → `failed_requests`         |
| czy klient zmienił adres IP      | NIE — VIP `10.0.0.100` cały czas                    |
| czy pliki dostępne po przełączeniu | `test2` — SHA256 zgodne                           |
| ograniczenia technologii         | `test4` — split-brain bez 3. węzła; sekcja Ograniczenia |

## Ograniczenia (do sekcji "Ograniczenia" sprawozdania)

Testy potwierdzają wprost ograniczenia opisane w koncepcji:

1. **Brak STONITH** — `stonith-enabled=false` w Pacemakerze, bo dwa laptopy
   bez IPMI/PDU nie dają możliwości "zabicia" peera. Konsekwencja:
   po split-brainie wymagana ręczna interwencja → `reset_after_splitbrain.sh`.

2. **2-node + brak qdevice** — `no-quorum-policy=ignore`, oba węzły
   "działają same" gdy stracą łączność. Test 4 to demonstruje.
   Rozwiązanie produkcyjne: trzeci host (VPS) jako `corosync-qnetd`.

3. **CGNAT u operatora PLAY** — uniemożliwia bezpośrednie połączenie
   WireGuard. Konieczność warstwy NAT-traversal (Tailscale — pod spodem
   nadal WG). Dokumentacja → sekcja "Architektura" / "Sieć".

4. **WAN latencja (~30-50 ms RTT) i jitter (WiFi)** — DRBD `protocol C`
   znacząco wydłuża czas zapisu (każdy fsync = round-trip). W produkcji
   rozważyć `protocol B` (ACK po RAM peer'a) lub asynchroniczny.

5. **Czas failover ~10-25 s w WAN** (vs ~3 s w LAN) — promotion DRBD
   przez wolne łącze jest dominującym czynnikiem. W produkcji:
   - tańszy łącze L2 (MPLS, dedykowany VPN-router)
   - wstępnie zsynchronizowany "warm standby"

## Po teście

- Każdy skrypt **na końcu wykonuje `restore_cluster`** — cofa standby,
  klaster wraca do stanu wyjściowego.
- Wyjątek: Test 4 — po split-brainie DRBD wymaga ręcznego resetu.
- Wszystkie metryki idą do `results/<timestamp>_*`. Możesz wkleić
  bezpośrednio w sprawozdanie albo zrobić własny wykres.

## Wynik dobrego testu

- ✅ `test1`: niedostępność 10-25 s (WAN), klient nie zmienia IP
- ✅ `test2`: SHA256 pre = post (bit-w-bit identyczne)
- ✅ `test3`: > 90% sond OK w trakcie resync (klient nie zauważa)
- ⚠️ `test4`: SPLIT-BRAIN potwierdza ograniczenie — pożądany rezultat
- ✅ `test5`: plik = albo całkowicie OK z SHA256, albo go nie ma
  (atomic write nigdy nie wystawi niekompletnego)
