#!/usr/bin/env bash
# Pull secret di GHCR per una nuova app, copiato da un namespace che ce l'ha già.
# Un SealedSecret è legato al suo namespace: per un namespace nuovo va
# risigillato. Il secret decifrato passa dal cluster a kubeseal in una pipe,
# senza toccare terminale o disco.
#
# Uso (dalla root del repo, di solito tramite make):
#   scripts/ghcr-pull.sh <app> [namespace-sorgente, default alfred]
set -euo pipefail

app=${1:?app mancante}
from=${2:-alfred}
test -d "apps/$app" || { echo "apps/$app non esiste" >&2; exit 1; }
out="apps/$app/ghcr-pull-secret.yaml"

kubectl -n "$from" get secret ghcr-pull -o json \
  | APP="$app" python3 -c '
import json, os, sys
s = json.load(sys.stdin)
json.dump({"apiVersion": "v1", "kind": "Secret", "type": s["type"],
           "metadata": {"name": "ghcr-pull", "namespace": os.environ["APP"]},
           "data": s["data"]}, sys.stdout)' \
  | kubeseal --controller-namespace kube-system -o yaml > "$out"

echo "$app: scritto $out (copiato da $from)"
