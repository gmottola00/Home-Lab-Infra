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
  │       └─ https://trip-ai.<tailnet>.ts.net → trip-ai-web    │
  │                                ── /api/* → trip-ai-backend │
  │  ArgoCD ── sync da questo repo (app-of-apps)               │
  │  Sealed Secrets ── secrets cifrati committati in Git       │
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
apps/
  trip-ai/                  # manifest kustomize dell'app (Deployment/Service/Ingress/secrets)
legacy/                     # vecchio draft Caddy + docker-compose (riferimento storico)
```

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
> gli stessi comandi). Adottarli nel loop GitOps è un miglioramento futuro.

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

## Fasi future

- [x] Trip-AI online end-to-end (backend + PWA web) ← siamo qui
- [ ] **TickUp**: Postgres + Redis per-app dentro il cluster (StatefulSet, senza
      porte host), Celery worker/beat come Deployment separati, stesso pattern
- [ ] **Observability**: kube-prometheus-stack + Grafana + Loki
- [ ] **Jarvis**: PC fisso (RTX 5080) come k3s agent on-demand — Wake-on-LAN dal
      mini PC, Ollama esposto sulla tailnet, poi orchestratore + MCP
- [ ] Auto-gestione della piattaforma: ArgoCD/operator/sealed-secrets adottati
      nel loop GitOps (app-of-apps anche per platform/)
