# Homelab — k3s + GitOps sul Minisforum UM790

Repo **source-of-truth** del cluster: tutto ciò che gira sull'homelab è descritto
qui e sincronizzato da ArgoCD. Obiettivo: infra comune per tutte le app
(Trip-AI, poi TickUp, poi Jarvis) e palestra di architettura.

```
                    Internet ──✗ (nessuna porta aperta sul router)
                                      │
iPhone ──[Tailscale]──────────────────┤
                                      ▼
  ┌────────────────────────────────────────────────────────────┐
  │ Minisforum UM790 · Ubuntu 24.04 · k3s single-node          │
  │                                                            │
  │  Tailscale Operator ── Ingress (cert LE *.ts.net)          │
  │       ├─ https://argocd.<tailnet>.ts.net  → ArgoCD UI      │
  │       ├─ https://grafana.<tailnet>.ts.net → Grafana        │
  │       ├─ https://interview.<tailnet>.ts.net → interview    │
  │       ├─ https://jarvis.<tailnet>.ts.net  → jarvis-web     │
  │       ├─ https://litellm.<tailnet>.ts.net → LiteLLM UI     │
  │       ├─ https://tickup.<tailnet>.ts.net  → tickup-web     │
  │       └─ https://trip-ai.<tailnet>.ts.net → trip-ai-web    │
  │                                ── /api/* → trip-ai-backend │
  │  ArgoCD ── sync da questo repo (app-of-apps)               │
  │  Sealed Secrets ── secrets cifrati committati in Git       │
  │  Prometheus + Loki ── metriche e log di ogni pod → Grafana │
  │  LiteLLM ── gateway LLM: chiavi virtuali, budget, routing  │
  │       ├─ claude-* → api.anthropic.com                      │
  │       └─ local/*  → egress tailnet → Ollama (PC con GPU)   │
  │  CloudNativePG ── pg-shared: un Postgres, un DB per app    │
  │       └─ dump notturni (pg_dump) su volume, 7 giorni       │
  └────────────────────────────────────────────────────────────┘
        DB/Auth: Supabase (cloud) per Trip-AI e TickUp; in-cluster
        pg-shared (Interview Trainer) e il Postgres di LiteLLM
        Immagini: GHCR, buildate da GitHub Actions nei repo delle app
```

## Flusso di deploy (GitOps)

1. Push su `main` nel repo dell'app (es. Trip-AI)
2. GitHub Actions builda l'immagine → push su GHCR (`:latest` + `:<sha>`)
3. Il workflow committa il nuovo tag in `apps/<app>/kustomization.yaml` **qui**
4. ArgoCD vede il commit e rolla la nuova versione — nessun comando sul server

## Struttura

```
bootstrap/root-app.yaml     # UNICA cosa applicata a mano: l'app-of-apps
bootstrap/apps/*.yaml       # le Application ArgoCD (una per app)
platform/                   # componenti piattaforma: values helm + manifest
  argocd/                   # values + ingress tailnet della UI
  sealed-secrets/
  tailscale-operator/
  observability/            # values helm dello stack + manifest (ns, password Grafana)
  postgres/                 # values dell'operator CNPG + Cluster pg-shared, DB, ruoli, backup
apps/
  trip-ai/                  # manifest kustomize dell'app (Deployment/Service/Ingress/secrets)
  jarvis/                   # come trip-ai + ServiceAccount e ClusterRole di sola lettura
  litellm/                  # gateway LLM: proxy + Postgres + egress verso Ollama
  interview/                # Interview Trainer: backend FastAPI su pg-shared
legacy/                     # vecchio draft Caddy + docker-compose (riferimento storico)
```

## Comandi quotidiani

Il `Makefile` raccoglie i comandi ricorrenti (`make` da solo elenca tutto).
Convenzione: `APP` è il nome della cartella in `apps/` — che è anche il
namespace — e `COMP` è `backend` o `web`.

```bash
make ps                          # pod di tutte le app + piattaforma
make status                      # nodi, Application ArgoCD, ingress tailnet
make logs APP=tickup COMP=web    # log in follow
make logs-prev APP=tickup        # log del container morto (CrashLoopBackOff)
make sh APP=trip-ai              # shell nel pod
make restart APP=tickup          # rollout restart + attesa
make diff APP=tickup             # cosa c'è in Git vs cosa gira davvero
make validate                    # dry-run server-side di tutte le app
make seal APP=tickup ENV_FILE=~/tickup.env
make obs                         # pod e volumi dello stack di observability
make obs-pass                    # password admin di Grafana
```

Il Makefile non fa deploy: quello resta di ArgoCD (`make argo-refresh` al
massimo evita di aspettare il polling).

## Bootstrap del cluster (una volta sola)

Prerequisiti in admin console Tailscale: **MagicDNS** + **HTTPS Certificates**
abilitati; ACL con `tag:k8s-operator`/`tag:k8s` e un **OAuth client** taggato
`tag:k8s-operator` (scope: Devices Core + Auth Keys, write).

```bash
# 1. k3s senza Traefik (l'ingress lo fa il Tailscale Operator)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -
mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config \
  && sudo chown "$USER" ~/.kube/config

# 2. Helm + kubeseal CLI
# (helm: https://helm.sh/docs/intro/install/ · kubeseal: release GitHub sealed-secrets)

# 3. Componenti piattaforma
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update

helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  -f platform/argocd/values.yaml
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  -n kube-system -f platform/sealed-secrets/values.yaml
helm upgrade --install tailscale-operator tailscale/tailscale-operator \
  -n tailscale --create-namespace -f platform/tailscale-operator/values.yaml \
  --set-string oauth.clientId="$TS_CLIENT_ID" \
  --set-string oauth.clientSecret="$TS_CLIENT_SECRET"

# 4. Accesso ArgoCD → questo repo (privato): deploy key in sola lettura
ssh-keygen -t ed25519 -f /tmp/argocd-deploy -N "" -C argocd@homelab
# → aggiungi /tmp/argocd-deploy.pub come Deploy Key (read-only) del repo su GitHub
kubectl -n argocd create secret generic repo-home-lab-infra \
  --from-literal=type=git \
  --from-literal=url=git@github.com:gmottola00/Home-Lab-Infra.git \
  --from-file=sshPrivateKey=/tmp/argocd-deploy
kubectl -n argocd label secret repo-home-lab-infra \
  argocd.argoproj.io/secret-type=repository

# 5. UI ArgoCD sulla tailnet + password iniziale
kubectl apply -f platform/argocd/ingress.yaml
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# 6. Accendi tutto: da qui in poi comanda Git
kubectl apply -f bootstrap/root-app.yaml
```

> Nota: ArgoCD, Sealed Secrets e l'operator sono installati via helm CLI al
> bootstrap e non ancora auto-gestiti da ArgoCD (upgrade = `helm upgrade` con
> gli stessi comandi). Lo stack di observability invece è già in GitOps, con
> Application multi-source: è il pattern da estendere anche a questi tre.

## Aggiungere una nuova app (il pattern)

1. Nel repo dell'app: `Dockerfile` (+ eventuale `Dockerfile.web`) e workflow CI
   che pushano su GHCR e bumpano il tag qui (copiare da Trip-AI)
2. Qui: cartella `apps/<nome>/` con kustomize (Namespace, Deployment, Service,
   Ingress `ingressClassName: tailscale`, secrets sigillati)
3. Secrets: `kubeseal` (vedi sotto) — mai secret in chiaro su Git
4. Qui: `bootstrap/apps/<nome>.yaml` (Application ArgoCD)
5. Push → l'app-of-apps la raccoglie da sola

### Sigillare un secret

```bash
kubectl create secret generic <nome> -n <namespace> \
  --from-literal=CHIAVE=valore --dry-run=client -o yaml \
  | kubeseal --controller-namespace kube-system -o yaml \
  > apps/<app>/sealed-secret.yaml
```

Il file cifrato è committabile: solo il controller nel cluster può decifrarlo.

## Gateway LLM (LiteLLM)

Tutte le chiamate ai modelli delle app passano da LiteLLM. La vera
`ANTHROPIC_API_KEY` vive solo in `litellm-secrets`; le app hanno una **chiave
virtuale** ciascuna, revocabile e con budget, e la spesa si vede per chiave su
`https://litellm.<tailnet>.ts.net/ui` (login con la master key).

| Endpoint (dal cluster) | Per cosa |
|---|---|
| `http://litellm-proxy.litellm.svc.cluster.local:4000/anthropic` | Claude con l'API nativa (pass-through: thinking, effort, structured outputs invariati) |
| `http://litellm-proxy.litellm.svc.cluster.local:4000/v1/messages` | formato Anthropic verso qualsiasi modello, anche `local/*` (LiteLLM traduce per Ollama) |

I modelli sono in `apps/litellm/config.yaml`: `claude-*` sono Anthropic,
`local/*` sono Ollama sul PC fisso, raggiunto dal Service `ollama-gpu` (egress
del Tailscale Operator verso `pop-os`). PC spento → fallback su
`claude-haiku-4-5`. Le ACL della tailnet devono permettere `tag:k8s` →
`pop-os:11434`.

**Primo deploy:**

```bash
# 1. secret (valori veri solo nel file locale, mai in Git)
cat > /tmp/litellm.env <<'ENV'
LITELLM_MASTER_KEY=sk-<random>
LITELLM_SALT_KEY=sk-<random, non cambiarlo più: cifra le chiavi nel DB>
ANTHROPIC_API_KEY=sk-ant-...
POSTGRES_PASSWORD=<random>
DATABASE_URL=postgresql://litellm:<stessa password>@litellm-postgres:5432/litellm
ENV
make seal APP=litellm ENV_FILE=/tmp/litellm.env && rm /tmp/litellm.env
# 2. commit + push → ArgoCD crea namespace, Postgres e proxy
# 3. una chiave virtuale per app: la crea e risigilla il secret dell'app con
#    quella al posto della chiave vera (gli altri valori restano come sono)
make litellm-rekey APP=jarvis BUDGET=20
make litellm-rekey APP=trip-ai BUDGET=20
# 4. commit + push, poi riavvia i backend (un secret nuovo non li riavvia da solo)
kubectl -n jarvis rollout restart deploy/jarvis-backend
kubectl -n trip-ai rollout restart deploy/trip-ai-backend
```

Trip-AI non ha filtro sui modelli: usa id datati (`claude-haiku-4-5-20251001`)
che il pass-through inoltra così come sono, ma che non sono nomi di
`config.yaml`. Gli alias delle chiavi sono unici: per rifare la chiave di
un'app revoca prima quella vecchia dalla UI (Virtual Keys → Delete).

## Postgres condiviso (CloudNativePG)

Un solo server Postgres per le app del cluster, `pg-shared` nel namespace
`databases`, gestito dall'operator **CloudNativePG**. Ogni app ha in Git il suo
database e il suo ruolo; l'operator li crea e ne mantiene la password.

| Pezzo | Dove |
|---|---|
| operator (chart `cloudnative-pg`) | `bootstrap/apps/postgres.yaml` → `cnpg-operator`, values in `platform/postgres/cnpg-values.yaml` |
| Cluster `pg-shared` (1 istanza, Postgres 17, 20Gi) + ruoli | `platform/postgres/manifests/cluster.yaml` |
| un `Database` per app | `platform/postgres/manifests/databases/<app>.yaml` |
| password dei ruoli (sigillate) | `platform/postgres/manifests/roles/<app>-sealed.yaml` |
| dump notturni | `platform/postgres/manifests/backup.yaml` |

Endpoint per le app: `pg-shared-rw.databases.svc.cluster.local:5432`.

**Aggiungere il database di un'app** (es. `foo`, con `apps/foo/` già esistente):

1. In `cluster.yaml`, sotto `managed.roles`, un ruolo `foo` con `passwordSecret: pg-role-foo`.
2. `databases/foo.yaml` (copia di `interview.yaml`), e le righe
   `databases/foo.yaml` e `roles/foo-sealed.yaml` in `platform/postgres/manifests/kustomization.yaml`.
3. `make pg-user APP=foo`: genera la password e sigilla `roles/foo-sealed.yaml` (per
   CNPG) e `apps/foo/db-sealed-secret.yaml` (Secret `foo-db` con `DATABASE_URL`, da
   montare nel Deployment con `envFrom`). La password non passa dal terminale.
4. Aggiungi `db-sealed-secret.yaml` alla kustomization dell'app, poi commit e push.

```bash
make pg-status                # cluster, database, ruoli, pod, PVC, job di backup
make pg-psql DB=interview     # psql come superuser nel primary
make pg-backup                # backup subito (job dal CronJob) con i log
make pg-backups               # elenco dei dump sul volume
```

**Backup.** Ogni notte alle 03:00 il CronJob `pg-backup` scrive in
`/backups/<data>/` `globals.sql` (ruoli) e un `pg_dump -Fc` per ogni database, e
tiene 7 giorni. Sono sullo stesso disco del database: proteggono da errori (DROP,
migrazione sbagliata, Cluster cancellato), non da un guasto del disco. Il passo
successivo è portarli fuori (S3). Restore di un DB:

```bash
# dal pod di un job o di `make pg-backups` con il volume montato
pg_restore -h pg-shared-rw -U postgres -d <db> --clean --if-exists /backups/<data>/<db>.dump
```

> **Attenzione:** l'unica StorageClass (`local-path`) ha `reclaimPolicy: Delete`.
> Cancellare il Cluster, il suo PVC o il namespace `databases` cancella i dati.
> Per questo Cluster, PVC dei backup e namespace hanno
> `argocd.argoproj.io/sync-options: Prune=false,Delete=false`: ArgoCD non li
> rimuove nemmeno se spariscono da Git. Un `Database` tolto da Git non fa
> `DROP DATABASE` (`databaseReclaimPolicy: retain`).

LiteLLM resta per ora sul suo Postgres (`apps/litellm/postgres.yaml`); il
trasloco su `pg-shared` è un passo successivo.

## Observability

Metriche e log di tutto il cluster, su `https://grafana.<tailnet>.ts.net`
(`make obs-pass` per la password admin).

| Pezzo | Cosa fa |
|---|---|
| kube-prometheus-stack | Prometheus + Alertmanager + Grafana + kube-state-metrics + node-exporter |
| Loki | archivio dei log, retention 30 giorni |
| Alloy | legge i log dei pod e li spedisce a Loki (sostituisce Promtail, EOL da marzo 2026) |

Cosa risolve, in concreto: `make logs-prev` mostra i log di **un solo** crash e li
perde al riavvio successivo. In Loki i log del pod distrutto restano, e si cercano
per namespace/pod/container/`app`:

```logql
{namespace="tickup"}                          # tutto il namespace
{app="tickup-backend"} |= "ERROR"             # solo gli errori del backend
```

Le tre Application (`kube-prometheus-stack`, `loki`, `alloy`) sono le prime
**multi-source**: la prima source è il chart Helm upstream, la seconda è questo repo
referenziato come `$values` dai `valueFiles`. Il chart resta upstream, la sua
configurazione resta versionata qui — è il pattern con cui adottare in futuro anche
ArgoCD, l'operator e sealed-secrets nel loop GitOps.

Tre scelte che sembrano strane e non lo sono:

- **Il control-plane k3s non viene raccolto.** Scheduler, controller-manager e proxy
  girano dentro l'unico processo k3s e bindano su `127.0.0.1`; etcd non esiste
  (sqlite embedded). Esporli richiederebbe flag in `/etc/rancher/k3s/config.yaml`
  sull'host, cioè configurazione fuori da Git, e su un single-node direbbero poco.
  I relativi scrape job **e le loro alert** sono spenti nei values: un target down
  per sempre insegna solo a ignorare le notifiche.
- **Alertmanager è installato ma muto.** Nessun receiver esterno finché non sappiamo
  quali alert sono davvero utili; per ora si guardano dalla UI.
- **Alloy è un Deployment a replica singola, non un DaemonSet.** Legge i log
  dall'API server, non dal filesystem del nodo: un DaemonSet farebbe vedere a ogni
  replica tutti i pod del cluster e, il giorno in cui Jarvis entra come secondo
  nodo, ogni riga arriverebbe a Loki due volte.

Se una metrica manca, si parte sempre da `make obs-targets` (target di scrape down).

### Metriche di ArgoCD

I Service `metrics` di ArgoCD sono spenti di default nel chart. Sono abilitati in
`platform/argocd/values.yaml`, ma vanno applicati con un `helm upgrade` **dopo** il
primo sync di kube-prometheus-stack — i ServiceMonitor sono CRD del Prometheus
Operator e prima non esistono:

```bash
helm upgrade --install argocd argo/argo-cd -n argocd -f platform/argocd/values.yaml
```

## Fasi future

- [x] Trip-AI online end-to-end (backend + PWA web)
- [x] **TickUp**: stesso pattern di Trip-AI (Supabase cloud come DB, niente
      Postgres/Redis in-cluster: Redis è inutilizzato nel codice e lo scheduling
      è APScheduler in-process → backend a replica singola)
- [x] **Observability**: kube-prometheus-stack + Grafana + Loki
- [x] **Jarvis (app)**: agente + console read-only del cluster, stesso pattern
      di Trip-AI più RBAC (ServiceAccount `jarvis` con ClusterRole `jarvis-reader`,
      niente accesso ai Secret). Stato in memoria → replica singola
- [x] **Gateway LLM**: LiteLLM + Postgres in-cluster, chiavi virtuali per app,
      Ollama sul PC fisso (RTX 5080) via egress tailnet con fallback su Claude
- [x] **Postgres condiviso**: CloudNativePG, `pg-shared` con un database per app
      dichiarato in Git, dump notturni su volume
- [ ] **Interview Trainer**: primo utente di `pg-shared`, generazione su GPU e
      valutazione su Haiku via LiteLLM ← siamo qui (manca la migrazione dei
      dati da SQLite, poi `replicas: 1`)
- [ ] Backup di `pg-shared` fuori dal nodo (S3 / barman-cloud) e LiteLLM su `pg-shared`
- [ ] **Jarvis (GPU)**: PC fisso come k3s agent on-demand — Wake-on-LAN dal
      mini PC, poi orchestratore + MCP
- [ ] Auto-gestione della piattaforma: ArgoCD/operator/sealed-secrets adottati
      nel loop GitOps (app-of-apps anche per platform/)
