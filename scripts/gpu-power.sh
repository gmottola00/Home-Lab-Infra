#!/usr/bin/env bash
# Accensione / spegnimento del PC con la GPU (pop-os) tramite la presa Zigbee
# gpu-plug (Sonoff S60ZBTPF, misura i watt).
#
#   scripts/gpu-power.sh status   # presa, watt, tailnet, Ollama
#   scripts/gpu-power.sh on       # presa ON → il BIOS fa partire il PC
#   scripts/gpu-power.sh off      # shutdown via SSH, attesa dei watt bassi, presa OFF
#
# ⚠️  La presa homelab-plug alimenta QUESTO nodo: lo script si rifiuta di
#     toccarla. Spegnerla = cluster giù e nessuno che possa riaccenderlo.
#
# Prerequisiti (una volta sola, vedi README "Zigbee e GPU"):
#   - BIOS di pop-os: Restore on AC Power Loss → Power On
#   - chiave ~/.ssh/gpu-poweroff su questo nodo, autorizzata su pop-os con
#     command="sudo /usr/bin/systemctl poweroff",restrict
#
# L'MQTT passa da `kubectl exec` nel pod di Mosquitto: la password dell'utente
# cli resta nel cluster.
set -euo pipefail

PLUG=${GPU_PLUG:-gpu-plug}
HOST=${GPU_HOST:-pop-os.tail682dc3.ts.net}
SSH_KEY=${GPU_SSH_KEY:-$HOME/.ssh/gpu-poweroff}
SSH_USER=${GPU_SSH_USER:-$USER}
# Sotto questa soglia il PC è spento (in soft-off un PC tira 1-3 W).
OFF_WATTS=${GPU_OFF_WATTS:-8}
TIMEOUT=${GPU_TIMEOUT:-180}

[[ "$PLUG" == homelab-plug ]] && { echo "homelab-plug alimenta il nodo: non la tocco." >&2; exit 1; }

mqtt() { kubectl -n iot exec deploy/mosquitto -c mosquitto -- "$@"; }

pub() { # pub <topic> <json>
  mqtt sh -c 'mosquitto_pub -h localhost -u cli -P "$CLI_PASSWORD" -t "$1" -m "$2"' _ "$1" "$2"
}

# Ultimo stato della presa (JSON). Prima chiede una lettura fresca, poi legge
# il messaggio retained aggiornato.
plug_json() {
  pub "zigbee2mqtt/$PLUG/get" '{"state":"","power":""}' >/dev/null
  sleep 2
  mqtt sh -c 'mosquitto_sub -h localhost -u cli -P "$CLI_PASSWORD" -t "zigbee2mqtt/$1" -C 1 -W 5' _ "$PLUG"
}

field() { python3 -c 'import json,sys; v=json.loads(sys.argv[1]).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"; }

read_plug() {
  local j
  j=$(plug_json) || { echo "nessuno stato da zigbee2mqtt/$PLUG (presa associata? nome giusto?)" >&2; exit 1; }
  STATE=$(field "$j" state)
  POWER=$(field "$j" power)
  POWER=${POWER:-0}
}

is_low() { python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)' "$1" "$OFF_WATTS"; }

set_plug() { pub "zigbee2mqtt/$PLUG/set" "{\"state\":\"$1\"}"; }

tailnet_up() { tailscale ping -c 1 --timeout 3s "${HOST%%.*}" >/dev/null 2>&1; }
ollama_up() { curl -sf -m 3 "http://$HOST:11434/api/tags" >/dev/null; }

status() {
  read_plug
  echo "presa $PLUG: $STATE, ${POWER} W"
  if tailnet_up; then echo "pop-os: sulla tailnet"; else echo "pop-os: non raggiungibile"; fi
  if ollama_up; then echo "ollama: su"; else echo "ollama: giù"; fi
}

on() {
  read_plug
  if [[ "$STATE" == ON ]] && ! is_low "$POWER"; then
    echo "già acceso (${POWER} W)"
  else
    if [[ "$STATE" == ON ]]; then
      # Presa accesa ma PC spento: serve il fronte OFF→ON perché il BIOS riparta.
      echo "presa ON ma ${POWER} W: la spengo e riaccendo"
      set_plug OFF
      sleep 5
    fi
    set_plug ON
    echo "presa ON, aspetto il boot (max ${TIMEOUT}s)..."
  fi
  local t=0
  until ollama_up; do
    (( t >= TIMEOUT )) && { echo "pop-os/Ollama non risponde dopo ${TIMEOUT}s: controlla il BIOS (Restore on AC Power Loss)" >&2; exit 1; }
    sleep 5; t=$((t + 5))
  done
  echo "GPU pronta: Ollama risponde su $HOST:11434 (${t}s)"
}

off() {
  read_plug
  if [[ "$STATE" == OFF ]]; then echo "presa già OFF"; return; fi
  if ! is_low "$POWER"; then
    test -f "$SSH_KEY" || { echo "manca $SSH_KEY: non stacco la corrente a un PC acceso" >&2; exit 1; }
    echo "shutdown di pop-os via SSH..."
    local rc=0
    ssh -i "$SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 \
      "$SSH_USER@$HOST" true || rc=$?
    # 255 è anche la connessione chiusa dal poweroff: lo dicono i watt se è andato.
    if (( rc != 0 && rc != 255 )); then
      echo "ssh fallito (rc=$rc): la presa resta ON" >&2; exit 1
    fi
  fi
  # Tre letture basse di fila (circa 20 s): un PC che sta ancora spegnendo
  # i dischi può scendere per un attimo e risalire.
  local t=0 low=0
  while (( low < 3 )); do
    (( t >= TIMEOUT )) && { echo "dopo ${TIMEOUT}s pop-os tira ancora ${POWER} W: la presa resta ON" >&2; exit 1; }
    read_plug
    if is_low "$POWER"; then low=$((low + 1)); else low=0; fi
    echo "  ${POWER} W"
    sleep 5; t=$((t + 8))
  done
  set_plug OFF
  echo "pop-os spento, presa OFF"
}

case "${1:-}" in
  status) status ;;
  on) on ;;
  off) off ;;
  *) echo "uso: $0 status|on|off" >&2; exit 2 ;;
esac
