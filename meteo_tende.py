"""
meteo-tende-ecowitt-voicemonkey

Servizio 24/7 che:
  1. Interroga periodicamente la stazione meteo Ecowitt.
  2. Valuta vento sostenuto, raffiche e pioggia rispetto a soglie configurabili.
  3. Se almeno una soglia e' superata, invia un trigger Voice Monkey (Alexa)
     per alzare le tende.
  4. Implementa una macchina a stati con isteresi (cooldown + reset)
     per evitare di rinviare il comando se le tende sono probabilmente gia' su.
  5. Opera solo nella fascia oraria e nei mesi configurati.
"""

from __future__ import annotations

import argparse
import logging
import logging.handlers
import signal
import sys
import time
from dataclasses import dataclass
from datetime import datetime, time as dtime, timedelta
from enum import Enum
from pathlib import Path
from typing import Optional

import requests
import yaml


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

CONFIG_PATH = Path(__file__).with_name("config.yaml")


def load_config(path: Path = CONFIG_PATH) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f)


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def setup_logging(cfg: dict) -> logging.Logger:
    log_cfg = cfg.get("logging", {})
    level = getattr(logging, log_cfg.get("level", "INFO").upper(), logging.INFO)

    logger = logging.getLogger("meteo_tende")
    logger.setLevel(level)
    logger.handlers.clear()

    fmt = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    stream = logging.StreamHandler(sys.stdout)
    stream.setFormatter(fmt)
    logger.addHandler(stream)

    log_file = log_cfg.get("file")
    if log_file:
        fh = logging.handlers.RotatingFileHandler(
            log_file,
            maxBytes=int(log_cfg.get("max_bytes", 2_097_152)),
            backupCount=int(log_cfg.get("backup_count", 5)),
            encoding="utf-8",
        )
        fh.setFormatter(fmt)
        logger.addHandler(fh)

    return logger


# ---------------------------------------------------------------------------
# Modello dati meteo
# ---------------------------------------------------------------------------

@dataclass
class WeatherSample:
    wind_speed: Optional[float]      # km/h (o unita' configurata)
    wind_gust: Optional[float]       # km/h
    rain_rate: Optional[float]       # mm/h
    timestamp: datetime


# ---------------------------------------------------------------------------
# Client Ecowitt
# ---------------------------------------------------------------------------

class EcowittClient:
    def __init__(self, cfg: dict, timeout: int, logger: logging.Logger):
        self.cfg = cfg
        self.timeout = timeout
        self.log = logger

    def fetch(self) -> Optional[WeatherSample]:
        params = {
            "application_key": self.cfg["application_key"],
            "api_key": self.cfg["api_key"],
            "mac": self.cfg["mac"],
            "call_back": "wind,rainfall,rainfall_piezo",
            "wind_speed_unitid": self.cfg.get("wind_speed_unitid", 7),
            "rainfall_unitid": self.cfg.get("rainfall_unitid", 12),
        }
        try:
            r = requests.get(self.cfg["base_url"], params=params, timeout=self.timeout)
            r.raise_for_status()
            payload = r.json()
        except (requests.RequestException, ValueError) as e:
            self.log.warning("Errore lettura Ecowitt: %s", e)
            return None

        if payload.get("code") != 0:
            self.log.warning("Ecowitt risposta non OK: %s", payload)
            return None

        data = payload.get("data") or {}
        wind = data.get("wind") or {}
        # Alcune stazioni (es. WS90/WS85 con sensore piezoelettrico) riportano
        # la pioggia sotto "rainfall_piezo" invece di "rainfall".
        rain = data.get("rainfall") or data.get("rainfall_piezo") or {}

        def _val(node: dict, key: str) -> Optional[float]:
            try:
                v = node.get(key, {}).get("value")
                return float(v) if v is not None else None
            except (TypeError, ValueError):
                return None

        sample = WeatherSample(
            wind_speed=_val(wind, "wind_speed"),
            wind_gust=_val(wind, "wind_gust"),
            # rain_rate = intensita' di pioggia istantanea (mm/h)
            rain_rate=_val(rain, "rain_rate"),
            timestamp=datetime.now(),
        )
        self.log.debug(
            "Meteo: wind=%s gust=%s rain_rate=%s",
            sample.wind_speed, sample.wind_gust, sample.rain_rate,
        )
        return sample


# ---------------------------------------------------------------------------
# Client Voice Monkey
# ---------------------------------------------------------------------------

class VoiceMonkeyClient:
    def __init__(self, cfg: dict, timeout: int, logger: logging.Logger):
        self.cfg = cfg
        self.timeout = timeout
        self.log = logger

    def trigger(self) -> bool:
        params = {
            "access_token": self.cfg["access_token"],
            "secret_token": self.cfg["secret_token"],
            "monkey": self.cfg["monkey"],
        }
        try:
            r = requests.get(self.cfg["base_url"], params=params, timeout=self.timeout)
            r.raise_for_status()
            self.log.info("Voice Monkey trigger OK: %s", r.text.strip())
            return True
        except requests.RequestException as e:
            self.log.error("Voice Monkey trigger FAIL: %s", e)
            return False


# ---------------------------------------------------------------------------
# Macchina a stati con isteresi
# ---------------------------------------------------------------------------

class State(Enum):
    IDLE = "IDLE"              # tende presumibilmente giu', possiamo triggerare
    TRIGGERED = "TRIGGERED"    # comando inviato di recente, attesa cooldown/reset


class HysteresisController:
    """
    Logica:
      - IDLE: se qualunque soglia e' superata -> invia trigger, passa a TRIGGERED,
        registra timestamp del trigger.
      - TRIGGERED:
          * se cooldown non e' ancora trascorso: non si fa nulla.
          * altrimenti: se le condizioni restano sotto la "soglia di rientro"
            (soglia * reset_margin) per almeno reset_minutes consecutivi,
            si torna a IDLE.
          * se invece le soglie sono ancora superate dopo il cooldown,
            si invia nuovamente il trigger e si riparte con il cooldown
            (caso in cui le tende sono state magari riabbassate manualmente
            durante una pausa del vento).
    """

    def __init__(self, soglie: dict, isteresi: dict, logger: logging.Logger):
        self.wind_speed_max = float(soglie["wind_speed_max"])
        self.wind_gust_max = float(soglie["wind_gust_max"])
        self.rain_rate_max = float(soglie["rain_rate_max"])

        self.cooldown = timedelta(minutes=float(isteresi["cooldown_minutes"]))
        self.reset_window = timedelta(minutes=float(isteresi["reset_minutes"]))
        self.reset_margin = float(isteresi["reset_margin"])

        self.state: State = State.IDLE
        self.last_trigger_at: Optional[datetime] = None
        self.calm_since: Optional[datetime] = None
        self.log = logger

    # --- valutazione soglie ----------------------------------------------

    def _above_threshold(self, s: WeatherSample) -> list[str]:
        reasons: list[str] = []
        if s.wind_speed is not None and s.wind_speed > self.wind_speed_max:
            reasons.append(f"wind_speed={s.wind_speed:.1f}>{self.wind_speed_max}")
        if s.wind_gust is not None and s.wind_gust > self.wind_gust_max:
            reasons.append(f"wind_gust={s.wind_gust:.1f}>{self.wind_gust_max}")
        if s.rain_rate is not None and s.rain_rate > self.rain_rate_max:
            reasons.append(f"rain_rate={s.rain_rate:.2f}>{self.rain_rate_max}")
        return reasons

    def _below_reset(self, s: WeatherSample) -> bool:
        """Tutti i valori (se disponibili) sotto soglia * margine."""
        ws_ok = s.wind_speed is None or s.wind_speed < self.wind_speed_max * self.reset_margin
        wg_ok = s.wind_gust is None or s.wind_gust < self.wind_gust_max * self.reset_margin
        # per la pioggia richiediamo zero pioggia (margine non ha senso vicino a 0)
        rn_ok = s.rain_rate is None or s.rain_rate <= 0.0
        return ws_ok and wg_ok and rn_ok

    # --- step principale --------------------------------------------------

    def evaluate(self, sample: WeatherSample, trigger_fn) -> None:
        now = sample.timestamp
        reasons = self._above_threshold(sample)
        above = bool(reasons)

        if self.state == State.IDLE:
            if above:
                self.log.warning("Soglia superata (%s): invio trigger.", ", ".join(reasons))
                if trigger_fn():
                    self.state = State.TRIGGERED
                    self.last_trigger_at = now
                    self.calm_since = None
            else:
                self.log.debug("IDLE, condizioni nella norma.")
            return

        # state == TRIGGERED
        in_cooldown = (
            self.last_trigger_at is not None
            and (now - self.last_trigger_at) < self.cooldown
        )

        if above:
            # condizioni di nuovo (o ancora) sopra soglia
            self.calm_since = None
            if in_cooldown:
                self.log.info(
                    "Soglia ancora superata (%s) ma in cooldown (%.1f min residui).",
                    ", ".join(reasons),
                    (self.cooldown - (now - self.last_trigger_at)).total_seconds() / 60.0,
                )
            else:
                self.log.warning(
                    "Cooldown scaduto e condizioni ancora critiche (%s): rinvio trigger.",
                    ", ".join(reasons),
                )
                if trigger_fn():
                    self.last_trigger_at = now
            return

        # condizioni rientrate
        if self._below_reset(sample):
            if self.calm_since is None:
                self.calm_since = now
                self.log.info("Condizioni rientrate sotto margine di reset, avvio finestra di calma.")
            elif (now - self.calm_since) >= self.reset_window and not in_cooldown:
                self.log.info("Finestra di calma completata: stato -> IDLE.")
                self.state = State.IDLE
                self.calm_since = None
        else:
            # sopra al margine di rientro ma sotto soglia: zona grigia, resetto contatore calma
            self.calm_since = None
            self.log.debug("Sotto soglia ma sopra margine di reset: attesa.")


# ---------------------------------------------------------------------------
# Finestra operativa
# ---------------------------------------------------------------------------

def _parse_hhmm(s: str) -> dtime:
    h, m = s.split(":")
    return dtime(int(h), int(m))


class OperatingWindow:
    def __init__(self, cfg: dict):
        self.start = _parse_hhmm(cfg["ora_inizio"])
        self.end = _parse_hhmm(cfg["ora_fine"])
        self.month_start = int(cfg["mese_inizio"])
        self.month_end = int(cfg["mese_fine"])

    def is_active(self, now: Optional[datetime] = None) -> bool:
        now = now or datetime.now()
        if not (self.month_start <= now.month <= self.month_end):
            return False
        t = now.time()
        if self.start <= self.end:
            return self.start <= t <= self.end
        # finestra che attraversa mezzanotte
        return t >= self.start or t <= self.end


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

_RUNNING = True


def _handle_signal(signum, _frame):
    global _RUNNING
    _RUNNING = False


def _parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="meteo_tende",
        description="Servizio meteo-tende Ecowitt + Voice Monkey.",
    )
    p.add_argument(
        "--test-trigger",
        action="store_true",
        help="Invia subito un comando Voice Monkey (alza tende) e termina. "
             "Ignora soglie, isteresi e finestra oraria. Utile per testare "
             "che le API e la routine Alexa funzionino.",
    )
    p.add_argument(
        "--check-meteo",
        action="store_true",
        help="Stampa una singola lettura della stazione meteo e termina.",
    )
    return p.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = _parse_args(argv)
    cfg = load_config()
    log = setup_logging(cfg)

    voice = VoiceMonkeyClient(
        cfg["voicemonkey"],
        timeout=int(cfg["polling"]["http_timeout_seconds"]),
        logger=log,
    )
    ecowitt = EcowittClient(
        cfg["ecowitt"],
        timeout=int(cfg["polling"]["http_timeout_seconds"]),
        logger=log,
    )

    if args.test_trigger:
        log.info("MODALITA' TEST: invio trigger Voice Monkey (alza tende)...")
        ok = voice.trigger()
        log.info("Esito test trigger: %s", "OK" if ok else "FAIL")
        return 0 if ok else 1

    if args.check_meteo:
        log.info("MODALITA' CHECK METEO: lettura singola dalla stazione...")
        sample = ecowitt.fetch()
        if sample is None:
            log.error("Lettura meteo fallita.")
            return 1
        log.info(
            "Lettura OK -> wind_speed=%s wind_gust=%s rain_rate=%s",
            sample.wind_speed, sample.wind_gust, sample.rain_rate,
        )
        return 0

    log.info("Avvio servizio meteo-tende-ecowitt-voicemonkey")

    controller = HysteresisController(cfg["soglie"], cfg["isteresi"], log)
    window = OperatingWindow(cfg["orario"])

    interval = int(cfg["polling"]["interval_seconds"])

    signal.signal(signal.SIGINT, _handle_signal)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, _handle_signal)

    while _RUNNING:
        try:
            if not window.is_active():
                log.debug("Fuori finestra operativa, sleep.")
            else:
                sample = ecowitt.fetch()
                if sample is not None:
                    controller.evaluate(sample, voice.trigger)
        except Exception:  # pragma: no cover - safety net per servizio 24/7
            log.exception("Errore non gestito nel ciclo principale.")

        # sleep "interrompibile"
        for _ in range(interval):
            if not _RUNNING:
                break
            time.sleep(1)

    log.info("Arresto servizio.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
