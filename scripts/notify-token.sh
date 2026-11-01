#!/usr/bin/env bash
# Token di un'app per notify-hub. Genera un token casuale e:
#   - lo sigilla in apps/<app>/notify-sealed-secret.yaml (Secret <app>-notify,
#     chiave NOTIFY_TOKEN), da montare nel Deployment dell'app con envFrom;
#   - scrive il suo sha256 in NOTIFY_APPS di apps/notify/kustomization.yaml.
# Il token non passa mai dal terminale; l'hash non è un segreto e va in Git.
#
# Uso (dalla root del repo, di solito tramite make):
#   scripts/notify-token.sh <app>
# Rilanciarlo ruota il token: dopo il sync riavvia il backend dell'app (l'hub
# si riavvia da solo, il ConfigMap generato cambia nome).
# Ricorda anche il namespace dell'app in apps/notify/networkpolicy.yaml.
set -euo pipefail

app=${1:?app mancante}
test -d "apps/$app" || { echo "apps/$app non esiste" >&2; exit 1; }
kust="apps/notify/kustomization.yaml"
out="apps/$app/notify-sealed-secret.yaml"

NOTIFY_TOKEN=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
export NOTIFY_TOKEN APP="$app"

python3 -c '
import base64, json, os, sys
app, tok = os.environ["APP"], os.environ["NOTIFY_TOKEN"]
json.dump({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
           "metadata": {"name": f"{app}-notify", "namespace": app},
           "data": {"NOTIFY_TOKEN": base64.b64encode(tok.encode()).decode()}}, sys.stdout)' \
  | kubeseal --controller-namespace kube-system -o yaml > "$out"

# Riscrive solo la riga NOTIFY_APPS, lasciando il resto del file com'è.
KUST="$kust" python3 -c '
import hashlib, json, os, re
app, tok, path = os.environ["APP"], os.environ["NOTIFY_TOKEN"], os.environ["KUST"]
text = open(path).read()
m = re.search(r"^(\s*- NOTIFY_APPS=)(.*)$", text, re.M)
assert m, f"NOTIFY_APPS non trovato in {path}"
apps = json.loads(m.group(2) or "{}")
apps[app] = hashlib.sha256(tok.encode()).hexdigest()
line = m.group(1) + json.dumps(dict(sorted(apps.items())), separators=(",", ":"))
open(path, "w").write(text[: m.start()] + line + text[m.end():])'

echo "$app: scritti $out e l'hash in $kust"
echo "→ $out nelle resources di apps/$app/kustomization.yaml, secretRef $app-notify nel Deployment,"
echo "  $app in apps/notify/networkpolicy.yaml; poi commit + push e rollout restart di $app-backend"
