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
  │       ├─ https://tickup.<tailnet>.ts.net  → tickup-web     │
  │       └─ https://trip-ai.<tailnet>.ts.net → trip-ai-web    │
  │                                ── /api/* → trip-ai-backend │
  │  ArgoCD ── sync da questo repo (app-of-apps)               │
  │  Sealed Secrets ── secrets cifrati committati in Git       │
  │  Prometheus + Loki ── metriche e log di ogni pod → Grafana │
  └────────────────────────────────────────────────────────────┘
        DB/Auth: Supabase (cloud) — nessun Postgres nel cluster (per ora)
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
apps/
  trip-ai/                  # manifest kustomize dell'app (Deployment/Service/Ingress/secrets)
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
- [x] **Observability**: kube-prometheus-stack + Grafana + Loki ← siamo qui
- [ ] **Jarvis**: PC fisso (RTX 5080) come k3s agent on-demand — Wake-on-LAN dal
      mini PC, Ollama esposto sulla tailnet, poi orchestratore + MCP
- [ ] Auto-gestione della piattaforma: ArgoCD/operator/sealed-secrets adottati
      nel loop GitOps (app-of-apps anche per platform/)
