#!/usr/bin/env bash
# Crea la chiave virtuale LiteLLM di un'app e risigilla apps/<app>/sealed-secret.yaml
# con quella chiave come ANTHROPIC_API_KEY. Gli altri valori del secret sono
# ripresi dal cluster così come sono: nessun .env in chiaro su disco, e la
# chiave non passa mai dal terminale.
#
# Uso (dalla root del repo, di solito tramite make):
#   scripts/litellm-rekey.sh <app> [modelli,separati,da,virgola] [budget $/30gg]
# Poi: rivedi il diff, commit, push, e riavvia il backend dell'app.
set -euo pipefail

app=${1:?app mancante}
models=${2:-}
budget=${3:-10}

# Niente "| head": chiuderebbe la pipe mentre make stampa ancora (broken pipe).
key=$(make -s litellm-key APP="$app" MODELS="$models" BUDGET="$budget")
key=${key%%$'\n'*}
case "$key" in sk-*) ;; *) echo "$app: creazione chiave fallita: $key" >&2; exit 1 ;; esac

kubectl -n "$app" get secret "$app-secrets" -o json \
  | KEY="$key" python3 -c '
import base64, json, os, sys
s = json.load(sys.stdin)
s["data"]["ANTHROPIC_API_KEY"] = base64.b64encode(os.environ["KEY"].encode()).decode()
meta = s["metadata"]
json.dump({"apiVersion": "v1", "kind": "Secret", "type": s.get("type", "Opaque"),
           "metadata": {"name": meta["name"], "namespace": meta["namespace"]},
           "data": s["data"]}, sys.stdout)' \
  | kubeseal --controller-namespace kube-system -o yaml > "apps/$app/sealed-secret.yaml"

echo "$app: chiave virtuale creata, apps/$app/sealed-secret.yaml risigillato"
echo "→ commit + push, poi: kubectl -n $app rollout restart deploy/$app-backend"
