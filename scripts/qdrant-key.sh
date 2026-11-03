#!/usr/bin/env bash
# Chiave API del Qdrant condiviso.
#
#   scripts/qdrant-key.sh          genera una chiave nuova e sigilla
#                                  platform/qdrant/manifests/sealed-secret.yaml
#                                  (ruotarla rompe le app finché non la ricopiano)
#   scripts/qdrant-key.sh <app>    copia la chiave del cluster in <app>-secrets
#                                  come QDRANT_API_KEY (apps/<app>/sealed-secret.yaml)
set -euo pipefail

app=${1:-}

if [ -z "$app" ]; then
  python3 -c 'import secrets; print(secrets.token_urlsafe(32), end="")' \
    | scripts/secret-add.sh qdrant qdrant-secrets QDRANT__SERVICE__API_KEY \
        platform/qdrant/manifests/sealed-secret.yaml
  echo "→ commit + push; poi per ogni app consumer: make qdrant-key APP=<app>"
  exit 0
fi

test -d "apps/$app" || { echo "apps/$app non esiste" >&2; exit 1; }
kubectl -n qdrant get secret qdrant-secrets -o jsonpath='{.data.QDRANT__SERVICE__API_KEY}' \
  | base64 -d \
  | scripts/secret-add.sh "$app" "$app-secrets" QDRANT_API_KEY "apps/$app/sealed-secret.yaml"
echo "→ controlla che $app sia in platform/qdrant/manifests/networkpolicy.yaml, poi commit + push"
