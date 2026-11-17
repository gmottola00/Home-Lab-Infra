#!/usr/bin/env bash
# Client OIDC di tsidp per un servizio: legge client ID e secret senza eco e li
# sigilla nel secret del servizio (sovrascrive quello esistente).
#
#   scripts/oidc-client.sh <servizio>      (di solito: make oidc-client NAME=...)
#
# Prima: https://idp.tail682dc3.ts.net → Add New Client con la redirect URI
# stampata qui sotto. Un servizio nuovo = un caso nel case.
set -euo pipefail

name=${1:?servizio mancante (es. grafana)}

case "$name" in
  grafana)
    ns=monitoring
    secret=grafana-oidc
    id_key=GF_AUTH_GENERIC_OAUTH_CLIENT_ID
    secret_key=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET
    out=platform/observability/manifests/grafana-oidc-sealed-secret.yaml
    redirect=https://grafana.tail682dc3.ts.net/login/generic_oauth
    ;;
  mathesar)
    # Un'unica variabile JSON (SSO_CONFIG_DICT) con dentro client ID e secret.
    ns=mathesar
    secret=mathesar-sso
    format=mathesar
    out=platform/mathesar/manifests/sso-sealed-secret.yaml
    redirect=https://mathesar.tail682dc3.ts.net/auth/oidc/tsidp/login/callback/
    ;;
  *)
    echo "servizio sconosciuto: $name (aggiungilo in scripts/oidc-client.sh)" >&2
    exit 1
    ;;
esac

echo "Redirect URI del client su tsidp: $redirect"
read -rp "Client ID: " client_id
read -rsp "Client secret: " client_secret; echo
test -n "$client_id" && test -n "$client_secret" || { echo "valori vuoti" >&2; exit 1; }

NS="$ns" SECRET="$secret" IDK="${id_key:-}" SK="${secret_key:-}" FORMAT="${format:-pair}" \
  ID="$client_id" SEC="$client_secret" python3 -c '
import base64, json, os, sys
e = os.environ
b = lambda v: base64.b64encode(v.encode()).decode()
if e["FORMAT"] == "mathesar":
    sso = {"version": 2, "providers": {"tsidp": {
        "type": "oidc", "provider_name": "Tailscale",
        "client_id": e["ID"], "secret": e["SEC"],
        "server_url": "https://idp.tail682dc3.ts.net"}}}
    data = {"SSO_CONFIG_DICT": b(json.dumps(sso))}
else:
    data = {e["IDK"]: b(e["ID"]), e["SK"]: b(e["SEC"])}
json.dump({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
           "metadata": {"name": e["SECRET"], "namespace": e["NS"]}, "data": data}, sys.stdout)' \
  | kubeseal --controller-namespace kube-system -o yaml > "$out"

echo "$ns/$secret sigillato in $out → commit + push"
