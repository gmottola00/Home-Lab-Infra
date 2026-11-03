#!/usr/bin/env bash
# Aggiunge (o sostituisce) una chiave in un secret sigillato, tenendo gli altri
# valori così come sono nel cluster. Il valore arriva da stdin e non passa mai
# dal terminale né da un file in chiaro.
#
# Uso (dalla root del repo, di solito tramite make):
#   <comando che stampa il valore> | scripts/secret-add.sh <ns> <secret> <KEY> <file-sigillato>
#
# Se il secret non è ancora nel cluster e il file sigillato non esiste, ne crea
# uno nuovo con la sola KEY. Se il file esiste ma il secret non è (ancora)
# decifrato, si ferma: sovrascriverlo perderebbe gli altri valori.
set -euo pipefail

ns=${1:?namespace mancante}
secret=${2:?secret mancante}
key=${3:?KEY mancante}
out=${4:?file di output mancante}

value=$(cat)
test -n "$value" || { echo "$secret: valore vuoto su stdin" >&2; exit 1; }

if current=$(kubectl -n "$ns" get secret "$secret" -o json 2>/dev/null); then
  :
elif [ -f "$out" ]; then
  echo "$out esiste ma $ns/$secret non è nel cluster: fai sync prima, o cancella il file" >&2
  exit 1
else
  current='{"type": "Opaque", "data": {}}'
fi

printf '%s' "$current" \
  | NS="$ns" SECRET="$secret" KEY="$key" VALUE="$value" python3 -c '
import base64, json, os, sys
s = json.load(sys.stdin)
data = s.get("data") or {}
data[os.environ["KEY"]] = base64.b64encode(os.environ["VALUE"].encode()).decode()
json.dump({"apiVersion": "v1", "kind": "Secret", "type": s.get("type", "Opaque"),
           "metadata": {"name": os.environ["SECRET"], "namespace": os.environ["NS"]},
           "data": data}, sys.stdout)' \
  | kubeseal --controller-namespace kube-system -o yaml > "$out"

echo "$ns/$secret: $key scritta in $out"
