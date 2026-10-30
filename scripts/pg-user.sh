#!/usr/bin/env bash
# Credenziali Postgres di un'app su pg-shared. Genera una password casuale e
# scrive due SealedSecret, senza che la password passi mai dal terminale o da
# un file in chiaro:
#   platform/postgres/manifests/roles/<app>-sealed.yaml  pg-role-<app> (databases)
#       basic-auth letto da CNPG per il ruolo <app> (managed.roles in cluster.yaml)
#   apps/<app>/db-sealed-secret.yaml                     <app>-db (<app>)
#       DATABASE_URL per l'app, da montare con envFrom
#
# Uso (dalla root del repo, di solito tramite make):
#   scripts/pg-user.sh <app>
# Prima: ruolo in cluster.yaml e databases/<app>.yaml. Rilanciarlo ruota la
# password: CNPG la applica da solo (label cnpg.io/reload), il backend dell'app
# va riavviato dopo il sync.
set -euo pipefail

app=${1:?app mancante}
test -d "apps/$app" || { echo "apps/$app non esiste" >&2; exit 1; }

role_file="platform/postgres/manifests/roles/$app-sealed.yaml"
db_file="apps/$app/db-sealed-secret.yaml"
mkdir -p "$(dirname "$role_file")"

# token_urlsafe: solo [A-Za-z0-9_-], va nell'URL senza escaping.
PG_PASSWORD=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
export PG_PASSWORD APP="$app"

python3 -c '
import base64, json, os, sys
app, pw = os.environ["APP"], os.environ["PG_PASSWORD"]
b64 = lambda s: base64.b64encode(s.encode()).decode()
json.dump({"apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/basic-auth",
           "metadata": {"name": f"pg-role-{app}", "namespace": "databases",
                        "labels": {"cnpg.io/reload": "true"}},
           "data": {"username": b64(app), "password": b64(pw)}}, sys.stdout)' \
  | kubeseal --controller-namespace kube-system -o yaml > "$role_file"

python3 -c '
import base64, json, os, sys
app, pw = os.environ["APP"], os.environ["PG_PASSWORD"]
url = f"postgresql+psycopg://{app}:{pw}@pg-shared-rw.databases.svc.cluster.local:5432/{app}"
json.dump({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
           "metadata": {"name": f"{app}-db", "namespace": app},
           "data": {"DATABASE_URL": base64.b64encode(url.encode()).decode()}}, sys.stdout)' \
  | kubeseal --controller-namespace kube-system -o yaml > "$db_file"

echo "$app: scritti $role_file e $db_file"
echo "→ controlla che siano in platform/postgres/manifests/kustomization.yaml e apps/$app/kustomization.yaml, poi commit + push"
