#!/usr/bin/env bash
# Collega a Mathesar tutti i database di pg-shared (i Database CR di CNPG,
# tranne quello interno di Mathesar) e prepara l'utente admin.
#
#   scripts/mathesar-connect.sh <email>     (di solito: make mathesar-connect)
#
# Per ogni database:
#   1. installa le funzioni SQL di Mathesar (schemi msar, __msar,
#      mathesar_types) col ruolo proprietario, l'unico che può creare schemi;
#   2. assegna all'utente il ruolo readonly (pg_read_all_data);
#   3. cancella da Mathesar la password del proprietario: dentro resta solo
#      quella di readonly.
# Idempotente: va rilanciato quando nasce un database nuovo e dopo ogni
# aggiornamento di Mathesar (reinstalla le funzioni SQL).
#
# <email> è quella con cui entri da tsidp: Mathesar abbina il login SSO
# all'utente con la stessa email. Le password viaggiano solo su stdin.
set -euo pipefail

email=${1:?email mancante}
pod=$(kubectl -n mathesar get pod -l app=mathesar -o jsonpath='{.items[0].metadata.name}')

CFG=$(EMAIL="$email" python3 -c '
import base64, json, os, subprocess
def kj(*a): return json.loads(subprocess.check_output(["kubectl", *a, "-o", "json"]))
dbs = []
for d in kj("-n", "databases", "get", "databases.postgresql.cnpg.io")["items"]:
    name, owner = d["spec"]["name"], d["spec"]["owner"]
    if name == "mathesar":
        continue
    s = kj("-n", "databases", "get", "secret", f"pg-role-{owner}")["data"]
    dbs.append({"name": name, "owner": owner, "password": base64.b64decode(s["password"]).decode()})
email = os.environ["EMAIL"].lower()
print(json.dumps({"email": email, "username": email.split("@")[0], "dbs": sorted(dbs, key=lambda d: d["name"])}))')

{
  printf 'CFG = %s\n' "$(printf %s "$CFG" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  cat <<'PY'
import json, os
import django
django.setup()
from mathesar.models.users import User
from mathesar.models.base import Server, Database, ConfiguredRole, UserDatabaseRoleMap
from mathesar.utils.permissions import set_up_preexisting_database_for_user

cfg = json.loads(CFG)
HOST, PORT = "pg-shared-rw.databases.svc.cluster.local", 5432

user = User.objects.filter(email=cfg["email"]).first()
if user is None:
    user = User(username=cfg["username"], email=cfg["email"])
    user.set_unusable_password()  # si entra solo da tsidp
    print("utente admin creato:", cfg["username"])
user.is_superuser = user.is_staff = True
user.save()

server, _ = Server.objects.update_or_create(host=HOST, port=PORT, defaults={"sslmode": "prefer"})
readonly, _ = ConfiguredRole.objects.update_or_create(
    name="readonly", server=server, defaults={"password": os.environ["READONLY_PASSWORD"]})

for d in cfg["dbs"]:
    database = Database.objects.filter(name=d["name"], server=server).first()
    if database is None:
        set_up_preexisting_database_for_user(HOST, PORT, d["name"], d["name"], d["owner"], d["password"], user)
        database = Database.objects.get(name=d["name"], server=server)
    else:
        database.install_sql(username=d["owner"], password=d["password"])
    UserDatabaseRoleMap.objects.update_or_create(
        user=user, database=database, defaults={"configured_role": readonly, "server": server})
    ConfiguredRole.objects.filter(server=server, name=d["owner"]).delete()
    print(f"{d['name']}: collegato, accesso readonly")
PY
} | kubectl -n mathesar exec -i "$pod" -- python -c 'import sys; exec(sys.stdin.read())'
