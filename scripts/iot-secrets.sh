#!/usr/bin/env bash
# Segreti del namespace iot, sigillati in apps/iot/sealed-secret.yaml (Secret
# iot-secrets):
#   secret.yaml   → letto da Zigbee2MQTT con `!secret` (network_key, mqtt_password)
#   Z2M_PASSWORD  → la stessa password, per l'utente z2m di Mosquitto
#   CLI_PASSWORD  → utente cli di Mosquitto (make gpu-*, zigbee-pair)
#
# La network key si genera UNA volta sola: se il Secret esiste già nel cluster
# la si riprende da lì, quindi rilanciare lo script ruota solo le password MQTT.
# Cambiarla vorrebbe dire riassociare tutti i device (NEW_NETWORK_KEY=1 per
# farlo apposta, con la rete vuota).
#
# Uso (dalla root del repo, di solito tramite make):
#   scripts/iot-secrets.sh
# Dopo il sync: rollout restart di mosquitto e zigbee2mqtt (i Secret non
# cambiano nome, i pod non si riavviano da soli).
set -euo pipefail

out="apps/iot/sealed-secret.yaml"

existing=""
if [[ "${NEW_NETWORK_KEY:-0}" != 1 ]] && kubectl -n iot get secret iot-secrets >/dev/null 2>&1; then
  existing=$(kubectl -n iot get secret iot-secrets -o jsonpath='{.data.secret\.yaml}' | base64 -d)
  echo "network key ripresa dal Secret nel cluster"
elif [[ -f "$out" && "${NEW_NETWORK_KEY:-0}" != 1 ]]; then
  echo "$out esiste ma il Secret non è nel cluster: non posso riprendere la network key." >&2
  echo "Aspetta il sync di ArgoCD, oppure NEW_NETWORK_KEY=1 per una rete nuova (riassocia tutto)." >&2
  exit 1
fi
export EXISTING="$existing"

python3 -c '
import base64, json, os, re, secrets, sys
existing = os.environ["EXISTING"]
m = re.search(r"^network_key:\s*(\[.*\])\s*$", existing, re.M)
key = json.loads(m.group(1)) if m else list(secrets.token_bytes(16))
assert len(key) == 16, "network_key deve avere 16 byte"
z2m, cli = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
secret_yaml = f"network_key: {json.dumps(key)}\nmqtt_password: {json.dumps(z2m)}\n"
b64 = lambda s: base64.b64encode(s.encode()).decode()
json.dump({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
           "metadata": {"name": "iot-secrets", "namespace": "iot"},
           "data": {"secret.yaml": b64(secret_yaml), "Z2M_PASSWORD": b64(z2m),
                    "CLI_PASSWORD": b64(cli)}}, sys.stdout)' \
  | kubeseal --controller-namespace kube-system -o yaml > "$out"

echo "scritto $out — commit + push, poi:"
echo "  kubectl -n iot rollout restart deploy/mosquitto deploy/zigbee2mqtt"
