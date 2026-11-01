#!/usr/bin/env bash
# Chiave VAPID di notify-hub: genera una chiave EC P-256 e la sigilla in
# apps/notify/sealed-secret.yaml (Secret notify-secrets, NOTIFY_VAPID_PRIVATE_KEY).
# La chiave privata non passa dal terminale né da un file in chiaro.
#
# ATTENZIONE: rilanciarlo RUOTA la chiave. Ogni sottoscrizione esistente, su
# ogni telefono e per ogni app, smette di funzionare: i push service rifiutano
# una firma diversa da quella con cui il browser si è iscritto. Le notifiche
# vanno riattivate da ogni dispositivo. Per questo chiede conferma se il file
# esiste già.
#
# Uso (dalla root del repo, di solito tramite make):
#   scripts/notify-vapid.sh
set -euo pipefail

out="apps/notify/sealed-secret.yaml"
if [[ -f "$out" ]]; then
  read -r -p "$out esiste: rigenerarlo invalida tutte le sottoscrizioni. Continuare? [s/N] " ok
  [[ "$ok" == "s" || "$ok" == "S" ]] || { echo "annullato"; exit 1; }
fi

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null \
  | python3 -c '
import base64, json, sys
pem = sys.stdin.read()
assert pem.startswith("-----BEGIN PRIVATE KEY-----"), "openssl non ha prodotto una chiave PEM"
json.dump({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
           "metadata": {"name": "notify-secrets", "namespace": "notify"},
           "data": {"NOTIFY_VAPID_PRIVATE_KEY": base64.b64encode(pem.encode()).decode()}}, sys.stdout)' \
  | kubeseal --controller-namespace kube-system -o yaml > "$out"

echo "notify: scritto $out"
echo "→ commit + push; se l'hub gira già: kubectl -n notify rollout restart deploy/notify-backend"
