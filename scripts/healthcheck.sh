#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh — Verifica salute del servizio meteo-tende sul Raspberry Pi
#
# Controlli eseguiti:
#   1. Unit systemd "meteo-tende" presente
#   2. Servizio "active (running)"
#   3. Servizio "enabled" (auto-start al boot)
#   4. Nessun restart anomalo recente
#   5. Processo Python in esecuzione
#   6. Log applicazione esiste e viene aggiornato (ultimo write < N minuti)
#   7. Nessun ERROR/CRITICAL nelle ultime N righe del log
#      + ultimo comando "alza tende" e ultimo superamento soglia
#   8. Connettività verso Ecowitt e Voice Monkey
#   9. config.yaml presente e leggibile + soglie trigger configurate
#
# Uso:
#   ./healthcheck.sh
#   ./healthcheck.sh --verbose
#
# Exit code:
#   0 = tutto OK
#   1 = uno o più check falliti
# =============================================================================

set -u

SERVICE_NAME="meteo-tende"
INSTALL_DIR="/home/pietro/meteo-tende-ecowitt-voicemokey"
LOG_FILE="${INSTALL_DIR}/meteo_tende.log"
CONFIG_FILE="${INSTALL_DIR}/config.yaml"
MAX_LOG_AGE_MINUTES=60        # soglia "soft": il log viene toccato solo quando c'e' qualcosa di rilevante
                              # (trigger, warning, rientro). In condizioni meteo calme puo' restare
                              # fermo a lungo anche con il servizio perfettamente attivo.
ERROR_TAIL_LINES=200          # quante righe finali del log analizzare per errori

VERBOSE=0
PAUSE=0
for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=1 ;;
    --pause|-p)   PAUSE=1 ;;
  esac
done
# Se lanciato a doppio click dal Desktop (stdin non e' un tty oppure parent e' un file manager),
# manteniamo aperta la finestra finche' l'utente non preme un tasto.
# Euristica semplice: se stdout e' un tty ma il padre non e' una shell interattiva => pausa.
if [[ -t 1 ]] && command -v ps >/dev/null 2>&1; then
  PARENT_CMD=$(ps -o comm= -p "$PPID" 2>/dev/null || true)
  case "$PARENT_CMD" in
    bash|zsh|sh|fish|dash|ksh|tmux|screen|sshd) ;;     # lanciato da shell: niente pausa
    *) PAUSE=1 ;;                                       # lanciato da file manager / .desktop / dock
  esac
fi

# ---- colori ----------------------------------------------------------------
if [[ -t 1 ]]; then
  C_OK="\033[1;32m"; C_KO="\033[1;31m"; C_WARN="\033[1;33m"; C_DIM="\033[2m"; C_END="\033[0m"
else
  C_OK=""; C_KO=""; C_WARN=""; C_DIM=""; C_END=""
fi

FAIL=0
WARN=0

pass() { echo -e "  ${C_OK}[ OK ]${C_END} $*"; }
fail() { echo -e "  ${C_KO}[FAIL]${C_END} $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${C_WARN}[WARN]${C_END} $*"; WARN=$((WARN+1)); }
info() { [[ $VERBOSE -eq 1 ]] && echo -e "  ${C_DIM}$*${C_END}"; return 0; }

section() { echo; echo -e "${C_DIM}== $* ==${C_END}"; }

# Concatena su stdout il log corrente e i suoi ruotati (solo quelli esistenti).
# Evita di passare a grep file inesistenti (es. il glob meteo_tende.log.* quando
# non c'e' rotazione) e di dipendere da opzioni grep poco portabili come -h/-o,
# non sempre supportate (es. BusyBox grep su immagini Pi minimali).
cat_logs() {
  local f
  for f in "${LOG_FILE}" "${LOG_FILE}".*; do
    [ -f "$f" ] && cat "$f"
  done 2>/dev/null
}

# ---- 1. unit esiste --------------------------------------------------------
section "systemd"
if ! systemctl list-unit-files | grep -q "^${SERVICE_NAME}\.service"; then
  fail "Unit ${SERVICE_NAME}.service non trovata"
  echo
  echo "Servizio non installato. Vedi README → Raspberry Pi."
  exit 1
fi
pass "Unit ${SERVICE_NAME}.service presente"

# ---- 2. active -------------------------------------------------------------
ACTIVE_STATE=$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || true)
if [[ "${ACTIVE_STATE}" == "active" ]]; then
  pass "Stato: active (running)"
else
  fail "Stato: ${ACTIVE_STATE}"
fi

# ---- 3. enabled ------------------------------------------------------------
ENABLED_STATE=$(systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null || true)
if [[ "${ENABLED_STATE}" == "enabled" ]]; then
  pass "Auto-start al boot: enabled"
else
  warn "Auto-start al boot: ${ENABLED_STATE} (usa: sudo systemctl enable ${SERVICE_NAME})"
fi

# ---- 4. restart anomali ----------------------------------------------------
N_RESTARTS=$(systemctl show "${SERVICE_NAME}" -p NRestarts --value 2>/dev/null || echo "0")
if [[ "${N_RESTARTS}" -eq 0 ]]; then
  pass "Restart counter: 0"
elif [[ "${N_RESTARTS}" -le 3 ]]; then
  warn "Restart counter: ${N_RESTARTS}"
else
  fail "Restart counter: ${N_RESTARTS} (servizio instabile)"
fi

# uptime del servizio
ACTIVE_SINCE=$(systemctl show "${SERVICE_NAME}" -p ActiveEnterTimestamp --value 2>/dev/null || true)
[[ -n "${ACTIVE_SINCE}" ]] && info "Attivo dal: ${ACTIVE_SINCE}"

# ---- 5. processo Python ----------------------------------------------------
section "processo"
MAIN_PID=$(systemctl show "${SERVICE_NAME}" -p MainPID --value 2>/dev/null || echo "0")
if [[ "${MAIN_PID}" != "0" && -d "/proc/${MAIN_PID}" ]]; then
  CMDLINE=$(tr '\0' ' ' < /proc/${MAIN_PID}/cmdline 2>/dev/null || echo "")
  pass "PID ${MAIN_PID} in esecuzione"
  info "cmd: ${CMDLINE}"

  # uso memoria
  if [[ -r /proc/${MAIN_PID}/status ]]; then
    RSS_KB=$(awk '/^VmRSS:/ {print $2}' /proc/${MAIN_PID}/status)
    [[ -n "${RSS_KB}" ]] && info "Memoria RSS: $((RSS_KB / 1024)) MB"
  fi
else
  fail "Processo principale non trovato (MainPID=${MAIN_PID})"
fi

# ---- 6. log file freschezza ------------------------------------------------
section "log applicazione"
if [[ ! -f "${LOG_FILE}" ]]; then
  warn "Log file non esiste ancora: ${LOG_FILE}"
else
  pass "Log file presente: ${LOG_FILE}"
  LOG_SIZE=$(stat -c %s "${LOG_FILE}" 2>/dev/null || echo 0)
  info "Dimensione: $((LOG_SIZE / 1024)) KB"

  LOG_MTIME=$(stat -c %Y "${LOG_FILE}" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  AGE_MIN=$(( (NOW - LOG_MTIME) / 60 ))

  # Formatta l'eta' in giorni/ore/minuti per leggibilita'
  AGE_D=$(( AGE_MIN / 1440 ))
  AGE_H=$(( (AGE_MIN % 1440) / 60 ))
  AGE_M=$(( AGE_MIN % 60 ))
  if (( AGE_D > 0 )); then
    AGE_HUMAN="${AGE_D}g ${AGE_H}h ${AGE_M}m"
  elif (( AGE_H > 0 )); then
    AGE_HUMAN="${AGE_H}h ${AGE_M}m"
  else
    AGE_HUMAN="${AGE_M}m"
  fi

  if [[ ${AGE_MIN} -le ${MAX_LOG_AGE_MINUTES} ]]; then
    pass "Ultimo write log: ${AGE_HUMAN} fa"
  else
    # Il log si scrive solo quando ci sono eventi (trigger / warning / rientro).
    # In condizioni normali puo' restare fermo a lungo: degradato a WARN, mai FAIL.
    # La vera prova di vita e' MainPID + /proc/PID gia' verificata sopra.
    HOUR=$(date +%H)
    if (( 10#$HOUR < 10 || 10#$HOUR >= 19 )); then
      info "Log fermo da ${AGE_HUMAN} (fuori fascia 10:00-19:00, normale)"
    else
      warn "Log fermo da ${AGE_HUMAN} (in fascia attiva, ma normale se meteo calmo)"
    fi
  fi

  # Data piu' vecchia presente nei log (corrente + ruotati): mostra quanto
  # storico e' ancora disponibile prima che la rotazione lo cancelli.
  # Le righe iniziano col timestamp "YYYY-MM-DD HH:MM:SS": ordino le righe
  # complete e prendo i primi 19 caratteri della piu' vecchia (cut), cosi'
  # evito grep -o (non sempre disponibile).
  OLDEST_TS=$(cat_logs | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' | sort | head -n 1 | cut -c1-19)
  if [[ -n "${OLDEST_TS}" ]]; then
    OLDEST_EPOCH=$(date -d "${OLDEST_TS}" +%s 2>/dev/null || echo 0)
    if [[ "${OLDEST_EPOCH}" -gt 0 ]]; then
      SPAN_MIN=$(( (NOW - OLDEST_EPOCH) / 60 ))
      SPAN_D=$(( SPAN_MIN / 1440 ))
      SPAN_H=$(( (SPAN_MIN % 1440) / 60 ))
      SPAN_M=$(( SPAN_MIN % 60 ))
      if (( SPAN_D > 0 )); then
        SPAN_HUMAN="${SPAN_D}g ${SPAN_H}h"
      elif (( SPAN_H > 0 )); then
        SPAN_HUMAN="${SPAN_H}h ${SPAN_M}m"
      else
        SPAN_HUMAN="${SPAN_M}m"
      fi
      pass "Storico log a partire da: ${OLDEST_TS} (${SPAN_HUMAN})"
    else
      pass "Storico log a partire da: ${OLDEST_TS}"
    fi
  fi

  # ---- 7. errori recenti nel log ------------------------------------------
  ERR_COUNT=$(tail -n ${ERROR_TAIL_LINES} "${LOG_FILE}" 2>/dev/null | grep -cE " (ERROR|CRITICAL) " || true)
  if [[ ${ERR_COUNT} -eq 0 ]]; then
    pass "Nessun ERROR/CRITICAL nelle ultime ${ERROR_TAIL_LINES} righe"
  else
    fail "${ERR_COUNT} ERROR/CRITICAL nelle ultime ${ERROR_TAIL_LINES} righe"
    echo -e "  ${C_DIM}Ultimi errori:${C_END}"
    tail -n ${ERROR_TAIL_LINES} "${LOG_FILE}" | grep -E " (ERROR|CRITICAL) " | tail -n 5 | sed 's/^/    /'
  fi

  # ---- 7b. ultimo trigger "alza tende" ------------------------------------
  # Cerca nell'intero log l'ultima conferma di trigger Voice Monkey andato a
  # buon fine. Marker: "Voice Monkey trigger OK".
  LAST_TRIGGER_LINE=$(grep -F "Voice Monkey trigger OK" "${LOG_FILE}" 2>/dev/null | tail -n 1 || true)
  if [[ -n "${LAST_TRIGGER_LINE}" ]]; then
    # Timestamp = primi 19 caratteri ("YYYY-MM-DD HH:MM:SS")
    LAST_TRIGGER_TS="${LAST_TRIGGER_LINE:0:19}"
    LAST_TRIGGER_EPOCH=$(date -d "${LAST_TRIGGER_TS}" +%s 2>/dev/null || echo 0)
    if [[ "${LAST_TRIGGER_EPOCH}" -gt 0 ]]; then
      TRG_AGE_MIN=$(( (NOW - LAST_TRIGGER_EPOCH) / 60 ))
      TRG_D=$(( TRG_AGE_MIN / 1440 ))
      TRG_H=$(( (TRG_AGE_MIN % 1440) / 60 ))
      TRG_M=$(( TRG_AGE_MIN % 60 ))
      if (( TRG_D > 0 )); then
        TRG_HUMAN="${TRG_D}g ${TRG_H}h ${TRG_M}m fa"
      elif (( TRG_H > 0 )); then
        TRG_HUMAN="${TRG_H}h ${TRG_M}m fa"
      else
        TRG_HUMAN="${TRG_M}m fa"
      fi
      pass "Ultimo comando 'alza tende': ${LAST_TRIGGER_TS} (${TRG_HUMAN})"
    else
      pass "Ultimo comando 'alza tende': ${LAST_TRIGGER_TS}"
    fi
  else
    info "Nessun comando 'alza tende' registrato nel log"
  fi

  # ---- 7c. ultimo superamento soglia --------------------------------------
  # Cerca l'ultima riga in cui un valore meteo ha superato una soglia. Il
  # controller logga il motivo nel formato "<param>=<val>><soglia>"
  # (es. "wind_speed=15.0>14.0"), presente sia quando invia il trigger sia
  # quando le condizioni restano critiche durante il cooldown.
  # Vengono inclusi anche i log ruotati (meteo_tende.log.1, .2, ...); le righe
  # iniziano col timestamp "YYYY-MM-DD HH:MM:SS", quindi un sort lessicale
  # mette l'evento piu' recente in fondo.
  LAST_EXCEED_LINE=$(cat_logs | grep -E '(wind_speed|wind_gust|rain_rate)=[0-9.]+>' | sort | tail -n 1)
  if [[ -n "${LAST_EXCEED_LINE}" ]]; then
    LAST_EXCEED_TS="${LAST_EXCEED_LINE:0:19}"
    # Estrai i motivi (testo tra le prime parentesi tonde, se presente) con sed
    # per non dipendere da grep -o.
    LAST_EXCEED_REASONS=$(printf '%s' "${LAST_EXCEED_LINE}" | sed -n 's/.*(\([^)]*\)).*/\1/p')
    LAST_EXCEED_EPOCH=$(date -d "${LAST_EXCEED_TS}" +%s 2>/dev/null || echo 0)
    if [[ "${LAST_EXCEED_EPOCH}" -gt 0 ]]; then
      EXC_AGE_MIN=$(( (NOW - LAST_EXCEED_EPOCH) / 60 ))
      EXC_D=$(( EXC_AGE_MIN / 1440 ))
      EXC_H=$(( (EXC_AGE_MIN % 1440) / 60 ))
      EXC_M=$(( EXC_AGE_MIN % 60 ))
      if (( EXC_D > 0 )); then
        EXC_HUMAN="${EXC_D}g ${EXC_H}h ${EXC_M}m fa"
      elif (( EXC_H > 0 )); then
        EXC_HUMAN="${EXC_H}h ${EXC_M}m fa"
      else
        EXC_HUMAN="${EXC_M}m fa"
      fi
      pass "Ultimo superamento soglia: ${LAST_EXCEED_TS} (${EXC_HUMAN})"
    else
      pass "Ultimo superamento soglia: ${LAST_EXCEED_TS}"
    fi
    [[ -n "${LAST_EXCEED_REASONS}" ]] && info "Valori oltre soglia: ${LAST_EXCEED_REASONS}"
  else
    # Nessun evento: mostrato comunque (riga neutra, sempre visibile).
    echo -e "  ${C_DIM}[ -- ]${C_END} Nessun superamento soglia finora registrato nel log"
  fi
fi

# ---- 8. connettività verso le API ------------------------------------------
# Verifichiamo solo che il server risponda (TCP+TLS+HTTP), non importa il
# codice (la root di queste API può restituire 404, ma il servizio è up).
section "connettività"
check_url() {
  local name="$1" url="$2"
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${url}" 2>/dev/null || echo "000")
  if [[ "${code}" != "000" ]]; then
    pass "${name} raggiungibile (HTTP ${code})"
  else
    warn "${name} non raggiungibile (${url})"
  fi
}
check_url "Ecowitt API"      "https://api.ecowitt.net/"
check_url "Voice Monkey API" "https://api.voicemonkey.io/"

# ---- 9. config.yaml --------------------------------------------------------
section "configurazione"
if [[ -r "${CONFIG_FILE}" ]]; then
  pass "config.yaml leggibile"
  # warning se i token sono ancora i placeholder
  if grep -qE 'YOUR_|REPLACE_|<.*>' "${CONFIG_FILE}"; then
    fail "config.yaml contiene placeholder non sostituiti"
  fi

  # Soglie configurate che fanno scattare il comando "alza tende".
  # Le chiavi sono uniche nel file, quindi un grep mirato e' sufficiente.
  _yaml_num() { grep -E "^[[:space:]]*$1:" "${CONFIG_FILE}" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*([0-9.]+).*/\1/'; }
  WIND_SPEED_MAX=$(_yaml_num wind_speed_max)
  WIND_GUST_MAX=$(_yaml_num wind_gust_max)
  RAIN_RATE_MAX=$(_yaml_num rain_rate_max)
  if [[ -n "${WIND_SPEED_MAX}${WIND_GUST_MAX}${RAIN_RATE_MAX}" ]]; then
    pass "Soglie trigger: vento ${WIND_SPEED_MAX:-?} km/h, raffica ${WIND_GUST_MAX:-?} km/h, pioggia ${RAIN_RATE_MAX:-?} mm/h"
  else
    warn "Soglie trigger non trovate in config.yaml"
  fi
else
  fail "config.yaml mancante o non leggibile: ${CONFIG_FILE}"
fi

# ---- riepilogo -------------------------------------------------------------
echo

# pausa finale (se lanciato a doppio click o con --pause): evita che la finestra
# del terminale si chiuda subito senza dare il tempo di leggere il risultato.
pause_if_needed() {
  if [[ ${PAUSE} -eq 1 ]]; then
    echo
    read -n 1 -s -r -p "Premi un tasto per chiudere..."
    echo
  fi
}

if [[ ${FAIL} -eq 0 && ${WARN} -eq 0 ]]; then
  echo -e "${C_OK}==> Tutto OK${C_END}"
  pause_if_needed
  exit 0
elif [[ ${FAIL} -eq 0 ]]; then
  echo -e "${C_WARN}==> OK con ${WARN} warning${C_END}"
  pause_if_needed
  exit 0
else
  echo -e "${C_KO}==> ${FAIL} check falliti, ${WARN} warning${C_END}"
  echo
  echo "Suggerimenti:"
  echo "  systemctl status ${SERVICE_NAME}"
  echo "  journalctl -u ${SERVICE_NAME} -n 100 --no-pager"
  echo "  tail -n 100 ${LOG_FILE}"
  pause_if_needed
  exit 1
fi
