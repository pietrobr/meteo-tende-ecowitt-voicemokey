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
#   8. Connettività verso Ecowitt e Voice Monkey
#   9. config.yaml presente e leggibile
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
MAX_LOG_AGE_MINUTES=10        # log deve essere stato aggiornato negli ultimi N minuti
ERROR_TAIL_LINES=200          # quante righe finali del log analizzare per errori

VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

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

  if [[ ${AGE_MIN} -le ${MAX_LOG_AGE_MINUTES} ]]; then
    pass "Ultimo write log: ${AGE_MIN} min fa"
  else
    # fuori dalla finestra oraria può essere normale (servizio in idle)
    HOUR=$(date +%H)
    if (( HOUR < 10 || HOUR >= 19 )); then
      warn "Log fermo da ${AGE_MIN} min (fuori fascia 10:00-19:00, probabilmente normale)"
    else
      fail "Log fermo da ${AGE_MIN} min (dentro fascia oraria attiva)"
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
fi

# ---- 8. connettività verso le API ------------------------------------------
section "connettività"
check_url() {
  local name="$1" url="$2"
  if curl -fsS --max-time 5 -o /dev/null "${url}"; then
    pass "${name} raggiungibile"
  else
    warn "${name} non raggiungibile (${url})"
  fi
}
check_url "Ecowitt API"     "https://api.ecowitt.net/"
check_url "Voice Monkey API" "https://api.voicemonkey.io/"

# ---- 9. config.yaml --------------------------------------------------------
section "configurazione"
if [[ -r "${CONFIG_FILE}" ]]; then
  pass "config.yaml leggibile"
  # warning se i token sono ancora i placeholder
  if grep -qE 'YOUR_|REPLACE_|<.*>' "${CONFIG_FILE}"; then
    fail "config.yaml contiene placeholder non sostituiti"
  fi
else
  fail "config.yaml mancante o non leggibile: ${CONFIG_FILE}"
fi

# ---- riepilogo -------------------------------------------------------------
echo
if [[ ${FAIL} -eq 0 && ${WARN} -eq 0 ]]; then
  echo -e "${C_OK}==> Tutto OK${C_END}"
  exit 0
elif [[ ${FAIL} -eq 0 ]]; then
  echo -e "${C_WARN}==> OK con ${WARN} warning${C_END}"
  exit 0
else
  echo -e "${C_KO}==> ${FAIL} check falliti, ${WARN} warning${C_END}"
  echo
  echo "Suggerimenti:"
  echo "  systemctl status ${SERVICE_NAME}"
  echo "  journalctl -u ${SERVICE_NAME} -n 100 --no-pager"
  echo "  tail -n 100 ${LOG_FILE}"
  exit 1
fi
