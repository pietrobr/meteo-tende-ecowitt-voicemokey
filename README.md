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

## Avvio manuale

```powershell
python meteo_tende.py
```

## Esecuzione come servizio Windows

Opzione consigliata: [NSSM](https://nssm.cc/).

```powershell
nssm install MeteoTende "C:\Path\to\.venv\Scripts\python.exe" "C:\Users\pietrobr\Documents\DEV\meteo-tende-ecowitt-voicemokey\meteo_tende.py"
nssm set MeteoTende AppDirectory "C:\Users\pietrobr\Documents\DEV\meteo-tende-ecowitt-voicemokey"
nssm start MeteoTende
```

## Esecuzione come servizio Linux (systemd)

`/etc/systemd/system/meteo-tende.service`:

```ini
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
