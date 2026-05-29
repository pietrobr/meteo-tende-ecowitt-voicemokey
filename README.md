# meteo-tende-ecowitt-voicemonkey

Servizio Python 24/7 che monitora una stazione meteo **Ecowitt** e, al superamento
di soglie configurabili su **vento**, **raffiche** o **pioggia**, invia un trigger
**Voice Monkey** per chiedere ad Alexa di **alzare le tende**.

## Caratteristiche

- Polling periodico API Ecowitt (`real_time`).
- Soglie configurabili: `wind_speed_max`, `wind_gust_max`, `rain_rate_max`.
- **Isteresi a stati** (IDLE / TRIGGERED) con:
  - `cooldown_minutes`: tempo minimo tra due trigger consecutivi.
  - `reset_minutes` + `reset_margin`: per tornare in IDLE servono N minuti
    consecutivi con tutti i valori sotto `soglia * margine`.
  - Evita di rinviare il comando "alza tende" quando le tende sono probabilmente
    gia' su, ma le rialza di nuovo se dopo il cooldown il maltempo persiste
    (potrebbero essere state riabbassate manualmente).
- **Finestra operativa** configurabile: ore (default 10:00-19:00) e mesi
  (default aprile-ottobre).
- Logging su stdout + file con rotazione.
- Gestione `SIGINT` / `SIGTERM` per shutdown pulito (compatibile con systemd / NSSM).

## Setup

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

Modifica `config.yaml` inserendo:

- `ecowitt.application_key`, `api_key`, `mac` (dal portale ecowitt.net).
- `voicemonkey.token` (token v2 da voicemonkey.io) e nome `monkey` (default `monkeytende`).
- Soglie, isteresi, orari secondo necessita'.

## Utilizzo da CLI

Lo script accetta i seguenti comandi:

```powershell
# Avvia il servizio in foreground (loop di polling continuo).
# Rispetta finestra oraria/mensile e isteresi.
python meteo_tende.py

# Specifica un file di configurazione alternativo
python meteo_tende.py --config C:\path\to\altro-config.yaml

# Invia SUBITO un trigger Voice Monkey (bypassa soglie, orario e isteresi).
# Utile per verificare che le tende si alzino davvero. Esce dopo l'invio.
python meteo_tende.py --test-trigger

# Esegue una sola lettura dalla stazione Ecowitt e stampa i valori. Esce.
python meteo_tende.py --check-meteo

# Mostra l'help completo
python meteo_tende.py --help
```

Su macOS / Linux il comando e' identico (sostituisci `python` con
`python3` se necessario).

## Esecuzione come servizio Windows (NSSM)

### Installazione

Opzione consigliata: [NSSM](https://nssm.cc/) (non-sucking service manager).

```powershell
nssm install MeteoTende "C:\Path\to\.venv\Scripts\python.exe" "C:\Users\pietrobr\Documents\DEV\meteo-tende-ecowitt-voicemokey\meteo_tende.py"
nssm set MeteoTende AppDirectory "C:\Users\pietrobr\Documents\DEV\meteo-tende-ecowitt-voicemokey"
nssm set MeteoTende AppStdout "C:\Users\pietrobr\Documents\DEV\meteo-tende-ecowitt-voicemokey\service-stdout.log"
nssm set MeteoTende AppStderr "C:\Users\pietrobr\Documents\DEV\meteo-tende-ecowitt-voicemokey\service-stderr.log"
nssm start MeteoTende
```

### Gestione

```powershell
nssm status MeteoTende
nssm restart MeteoTende
nssm stop MeteoTende
```

### Disinstallazione

```powershell
nssm stop MeteoTende
nssm remove MeteoTende confirm
```

In alternativa via `sc.exe` (built-in Windows):

```powershell
sc.exe stop MeteoTende
sc.exe delete MeteoTende
```

## Esecuzione come servizio macOS (launchd)

Su macOS i servizi user-level si gestiscono con **launchd** tramite file
`.plist` in `~/Library/LaunchAgents/`.

### Installazione

1. Crea il file `~/Library/LaunchAgents/com.pietrobr.meteotende.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.pietrobr.meteotende</string>

    <key>ProgramArguments</key>
    <array>
        <string>/Users/USERNAME/meteo-tende/.venv/bin/python</string>
        <string>/Users/USERNAME/meteo-tende/meteo_tende.py</string>
    </array>

    <key>WorkingDirectory</key>
    <string>/Users/USERNAME/meteo-tende</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/Users/USERNAME/meteo-tende/service-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/USERNAME/meteo-tende/service-stderr.log</string>
</dict>
</plist>
```

Sostituisci `USERNAME` con il tuo utente macOS.

2. Carica e avvia il servizio:

```bash
launchctl load  ~/Library/LaunchAgents/com.pietrobr.meteotende.plist
launchctl start com.pietrobr.meteotende
```

### Gestione

```bash
launchctl list | grep meteotende
launchctl stop  com.pietrobr.meteotende
launchctl start com.pietrobr.meteotende
```

### Disinstallazione

```bash
launchctl unload ~/Library/LaunchAgents/com.pietrobr.meteotende.plist
rm ~/Library/LaunchAgents/com.pietrobr.meteotende.plist
```

## Esecuzione su Raspberry Pi (Pi 2 / Raspberry Pi OS)

Il Raspberry Pi 2 (ARMv7, 1 GB RAM) e' piu' che sufficiente per questo
servizio: i requisiti sono trascurabili (un HTTP request al minuto).
La procedura vale anche per Pi 3 / Pi 4 / Pi Zero 2.

### Prerequisiti

Su Raspberry Pi OS (Bookworm o Bullseye):

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip git
python3 --version   # deve essere >= 3.9
```

> **Nota Pi 2 (32-bit)**: se sei ancora su Bullseye e Python e' troppo vecchio,
> aggiorna a Raspberry Pi OS Bookworm (Python 3.11). Le dipendenze del progetto
> sono pure Python, quindi NON serve compilare nulla con `gcc`.

### Installazione

```bash
# 1. Clona il repo (o copia i file via scp)
cd /opt
sudo git clone https://github.com/pietrobr/meteo-tende-ecowitt-voicemokey.git meteo-tende
sudo chown -R pi:pi /opt/meteo-tende
cd /opt/meteo-tende

# 2. Crea venv + dipendenze
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# 3. Crea config.yaml dal template e compila i secret
cp config.example.yaml config.yaml
nano config.yaml

# 4. Test rapido
python meteo_tende.py --test-trigger    # invia trigger Voice Monkey
python meteo_tende.py --check-meteo     # legge una volta dalla stazione
```

### Avvio come servizio (systemd)

Crea `/etc/systemd/system/meteo-tende.service`:

```ini
[Unit]
Description=Meteo Tende Ecowitt VoiceMonkey
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pi
WorkingDirectory=/opt/meteo-tende
ExecStart=/opt/meteo-tende/.venv/bin/python /opt/meteo-tende/meteo_tende.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now meteo-tende
sudo systemctl status meteo-tende
journalctl -u meteo-tende -f          # log in tempo reale
```

### Aggiornamento del codice

```bash
cd /opt/meteo-tende
sudo systemctl stop meteo-tende
git pull
.venv/bin/pip install -r requirements.txt
sudo systemctl start meteo-tende
```

### Health check (`scripts/healthcheck.sh`)

Script di verifica salute del servizio, da eseguire sul Pi dopo l'installazione
o per troubleshooting. Esegue 9 controlli: unit systemd presente, `active`,
`enabled`, restart counter, processo Python in esecuzione (PID + `/proc`),
freschezza del log applicazione, assenza di `ERROR`/`CRITICAL` nelle ultime
righe, connettivita' verso Ecowitt e Voice Monkey, `config.yaml` leggibile.

```bash
cd ~/meteo-tende-ecowitt-voicemokey   # o /opt/meteo-tende
chmod +x scripts/healthcheck.sh        # solo la prima volta
./scripts/healthcheck.sh               # esecuzione normale (terminale)
./scripts/healthcheck.sh --verbose     # mostra dettagli extra (PID, RSS, ecc.)
./scripts/healthcheck.sh --pause       # forza pausa "premi un tasto" prima di uscire
```

**Exit code**: `0` = tutto OK (anche con soli WARN), `1` = almeno un FAIL.

**Comportamenti notevoli**:

- Il log applicazione viene scritto solo in presenza di eventi (trigger,
  warning, rientro). Se rimane fermo a lungo con meteo calmo lo script genera
  al massimo un `WARN` (mai un `FAIL`): la vera prova di vita e' il processo
  Python verificato via `MainPID` + `/proc/<pid>`.
- Le API Ecowitt e Voice Monkey vengono considerate raggiungibili anche se
  rispondono con codici HTTP non‑2xx (es. 404 sulla root): cio' che conta e'
  che il server abbia risposto in tempo (TCP + TLS + HTTP OK).
- **Auto‑pausa a doppio click**: se lo script viene lanciato dal file manager
  o da una shortcut Desktop (processo padre non‑shell), aspetta automaticamente
  la pressione di un tasto prima di chiudere la finestra, cosi' i risultati
  restano leggibili. Da terminale il comportamento e' invariato (nessuna pausa,
  salvo `--pause`).

Shortcut sul Desktop del Pi:

```bash
ln -sf ~/meteo-tende-ecowitt-voicemokey/scripts/healthcheck.sh ~/Desktop/healthcheck.sh
chmod +x ~/meteo-tende-ecowitt-voicemokey/scripts/healthcheck.sh
```

### Disinstallazione

```bash
sudo systemctl disable --now meteo-tende
sudo rm /etc/systemd/system/meteo-tende.service
sudo systemctl daemon-reload
sudo rm -rf /opt/meteo-tende
```

### Accorgimenti per esecuzione 24/7 su Pi

- Imposta il fuso orario corretto: `sudo raspi-config` → Localisation → Timezone
  (l'orario del config `ora_inizio` / `ora_fine` usa il tempo locale del Pi).
- Sincronizza l'ora con NTP (gia' attivo di default su Raspberry Pi OS).
- Se usi una microSD, il log e' su `/opt/meteo-tende/meteo_tende.log` con
  rotazione automatica (~12 MB max), quindi non usurera' la scheda.
- Considera di alimentare il Pi con un alimentatore ufficiale 2.5A+ per
  evitare brown-out durante l'uso 24/7.

## Esecuzione come servizio Linux (systemd, generico)

`/etc/systemd/system/meteo-tende.service`:
[Unit]
Description=Meteo Tende Ecowitt VoiceMonkey
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/meteo-tende
ExecStart=/opt/meteo-tende/.venv/bin/python /opt/meteo-tende/meteo_tende.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now meteo-tende
```

Per disinstallare:

```bash
sudo systemctl disable --now meteo-tende
sudo rm /etc/systemd/system/meteo-tende.service
sudo systemctl daemon-reload
```

## Logging

Il logging e' configurato in `config.yaml` sezione `logging`. Valori di default
(sicuri per esecuzione 24/7):

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| `level` | `INFO` | Livello minimo (`DEBUG`, `INFO`, `WARNING`, `ERROR`). |
| `file` | `meteo_tende.log` | Path del file di log (relativo o assoluto). |
| `max_bytes` | `2097152` (2 MB) | Dimensione massima del singolo file prima della rotazione. |
| `backup_count` | `5` | Numero massimo di file ruotati conservati. |

La rotazione automatica (`RotatingFileHandler`) impedisce al log di crescere
all'infinito: con i default occupa al massimo **~12 MB** sul disco
(`meteo_tende.log` + `meteo_tende.log.1` ... `meteo_tende.log.5`).
Imposta `level: "DEBUG"` solo temporaneamente per troubleshooting: la verbosita'
moltiplica rapidamente la dimensione del log.

## Note sui parametri Ecowitt

L'API `real_time` restituisce sotto `data.wind` i campi `wind_speed` e
`wind_gust`, e sotto `data.rainfall` il campo `rain_rate` (intensita' di pioggia
istantanea). Le unita' di misura dipendono da `wind_speed_unitid` e
`rainfall_unitid`:

- `wind_speed_unitid`: 6=m/s, 7=km/h (default), 9=mph.
- `rainfall_unitid`: 12=mm (default), 13=in.

Per "rilevazione pioggia" puoi impostare `rain_rate_max: 0.0` per scattare
appena la stazione misura una qualsiasi precipitazione.

## Note sul trigger Voice Monkey

Viene usata l'API v2 (`https://api-v2.voicemonkey.io/trigger?token=...&device=monkeytende`).
Verifica sul tuo account quale endpoint/parametro e' richiesto e adatta
`voicemonkey.base_url` / `monkey` in `config.yaml` se necessario.
