#!/usr/bin/env bash
# Segreti di Mathesar, generati e sigillati senza passare dal terminale:
#   platform/postgres/manifests/roles/mathesar-sealed.yaml  pg-role-mathesar (ruolo CNPG)
#   platform/postgres/manifests/roles/readonly-sealed.yaml  pg-role-readonly (ruolo CNPG)
#   platform/mathesar/manifests/sealed-secret.yaml          mathesar-secrets:
#       POSTGRES_PASSWORD (ruolo mathesar), SECRET_KEY (Django: cifra le
#       password salvate in Mathesar), READONLY_PASSWORD (per make mathesar-connect)
#
# Rilanciarlo ruota tutto: dopo il sync riavvia Mathesar e rilancia
# make mathesar-connect (la password di readonly salvata in Mathesar cambia).
set -euo pipefail

gen() { python3 -c 'import secrets; print(secrets.token_urlsafe(32))'; }
MATHESAR_PW=$(gen) READONLY_PW=$(gen) SECRET_KEY=$(gen)$(gen)
export MATHESAR_PW READONLY_PW SECRET_KEY

role() {  # role <nome> <variabile con la password>
  ROLE="$1" PWVAR="$2" python3 -c '
import base64, json, os, sys
r, pw = os.environ["ROLE"], os.environ[os.environ["PWVAR"]]
b = lambda s: base64.b64encode(s.encode()).decode()
json.dump({"apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/basic-auth",
           "metadata": {"name": f"pg-role-{r}", "namespace": "databases",
                        "labels": {"cnpg.io/reload": "true"}},
           "data": {"username": b(r), "password": b(pw)}}, sys.stdout)' \
    | kubeseal --controller-namespace kube-system -o yaml \
        > "platform/postgres/manifests/roles/$1-sealed.yaml"
}

role mathesar MATHESAR_PW
role readonly READONLY_PW

python3 -c '
import base64, json, os, sys
b = lambda s: base64.b64encode(s.encode()).decode()
json.dump({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
           "metadata": {"name": "mathesar-secrets", "namespace": "mathesar"},
           "data": {"POSTGRES_PASSWORD": b(os.environ["MATHESAR_PW"]),
                    "SECRET_KEY": b(os.environ["SECRET_KEY"]),
                    "READONLY_PASSWORD": b(os.environ["READONLY_PW"])}}, sys.stdout)' \
  | kubeseal --controller-namespace kube-system -o yaml > platform/mathesar/manifests/sealed-secret.yaml

echo "Sigillati pg-role-mathesar, pg-role-readonly e mathesar-secrets → commit + push"
