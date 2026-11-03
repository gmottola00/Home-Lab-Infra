# Comandi ricorrenti dell'homelab. Niente logica di deploy: quella è di ArgoCD.
# Convenzione sfruttata ovunque: namespace == nome app, deployment == <app>-<comp>.
#
#   make logs APP=tickup COMP=backend
#   make restart APP=trip-ai COMP=web
#   make diff APP=tickup

APP  ?= trip-ai
NS   ?= $(APP)
COMP ?= backend
TAIL ?= 200
BUDGET ?= 10
MODELS ?=
KEY_VAR ?= ANTHROPIC_API_KEY
DB ?= postgres

APPS := $(notdir $(wildcard apps/*))
DEPLOY := $(APP)-$(COMP)

# Fallisce presto se APP non è una cartella sotto apps/ (typo = messaggio chiaro
# invece di un "No resources found" a caso).
check-app = @test -d apps/$(APP) || { \
	echo "APP='$(APP)' non esiste. Disponibili: $(APPS)"; exit 1; }

.DEFAULT_GOAL := help

##@ Info

.PHONY: help
help: ## Mostra questi comandi
	@awk 'BEGIN {FS = ":.*##"; printf "\nUso: make <target> [APP=%s COMP=backend|web]\n", "$(APP)"} \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } \
		/^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\nApp: $(APPS)\n"

.PHONY: ps
ps: ## Pod di tutte le app + piattaforma
	@kubectl get pods -A -o wide \
		--field-selector=status.phase!=Succeeded \
		| grep -vE '^(kube-system|kube-node-lease|kube-public)\b' || true

.PHONY: status
status: ## Nodi, Application ArgoCD e ingress tailnet
	@kubectl get nodes -o wide
	@echo
	@kubectl -n argocd get applications \
		-o custom-columns=APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revision
	@echo
	@kubectl get ingress -A

.PHONY: images
images: ## Immagini realmente in esecuzione (confronto con i tag in Git)
	@kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\n"}{end}' \
		| grep ghcr.io | sort
	@echo "--- kustomization.yaml (source of truth) ---"
	@grep -A1 'name: ghcr.io' apps/*/kustomization.yaml | grep -E 'name:|newTag:'

.PHONY: events
events: ## Eventi recenti del namespace APP
	$(call check-app)
	@kubectl -n $(NS) get events --sort-by=.lastTimestamp | tail -30

.PHONY: top
top: ## Consumo CPU/RAM di nodi e pod
	@kubectl top nodes 2>/dev/null || echo "metrics-server non disponibile"
	@echo
	@kubectl top pods -A --sort-by=memory 2>/dev/null | head -20

##@ Debug app

.PHONY: logs
logs: ## Log in follow di APP/COMP
	$(call check-app)
	kubectl -n $(NS) logs -f deploy/$(DEPLOY) --tail=$(TAIL) --all-containers --prefix

.PHONY: logs-prev
logs-prev: ## Log del container precedente (post-crash / CrashLoopBackOff)
	$(call check-app)
	kubectl -n $(NS) logs deploy/$(DEPLOY) --previous --tail=$(TAIL) --all-containers

.PHONY: sh
sh: ## Shell dentro il pod di APP/COMP
	$(call check-app)
	kubectl -n $(NS) exec -it deploy/$(DEPLOY) -- sh -c 'exec bash 2>/dev/null || exec sh'

.PHONY: describe
describe: ## Describe di deployment e pod di APP/COMP
	$(call check-app)
	kubectl -n $(NS) describe deploy/$(DEPLOY)
	kubectl -n $(NS) describe pod -l app=$(DEPLOY)

.PHONY: restart
restart: ## Rollout restart di APP/COMP e attesa del rollout
	$(call check-app)
	kubectl -n $(NS) rollout restart deploy/$(DEPLOY)
	kubectl -n $(NS) rollout status deploy/$(DEPLOY) --timeout=180s

.PHONY: rollout
rollout: ## Stato del rollout in corso
	$(call check-app)
	kubectl -n $(NS) rollout status deploy/$(DEPLOY) --timeout=180s

.PHONY: pf
pf: ## Port-forward del backend su localhost:8000
	$(call check-app)
	kubectl -n $(NS) port-forward deploy/$(APP)-backend 8000:8000

##@ Manifest (locale, nessuna scrittura sul cluster)

.PHONY: build
build: ## Renderizza i manifest kustomize di APP
	$(call check-app)
	kubectl kustomize apps/$(APP)

.PHONY: diff
diff: ## Diff fra i manifest di APP in Git e ciò che gira nel cluster
	$(call check-app)
	@kubectl kustomize apps/$(APP) | kubectl diff -f - || true

.PHONY: validate
validate: ## Dry-run server-side di tutte le app (da fare prima del push)
	@for a in $(APPS); do \
		echo "== $$a"; \
		if kubectl get ns $$a >/dev/null 2>&1; then \
			kubectl kustomize apps/$$a | kubectl apply --dry-run=server -f - >/dev/null || exit 1; \
		else \
			kubectl kustomize apps/$$a | kubectl apply --dry-run=client -f - >/dev/null || exit 1; \
			echo "   (ns $$a non ancora nel cluster: validazione solo client-side)"; \
		fi; \
	done
	@echo "== observability"
	@if kubectl get ns monitoring >/dev/null 2>&1; then \
		kubectl kustomize platform/observability/manifests \
			| kubectl apply --dry-run=server -f - >/dev/null || exit 1; \
	else \
		kubectl kustomize platform/observability/manifests \
			| kubectl apply --dry-run=client -f - >/dev/null || exit 1; \
		echo "   (ns monitoring non ancora nel cluster: validazione solo client-side)"; \
	fi
	@echo "== postgres"
	@if kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1 && kubectl get ns databases >/dev/null 2>&1; then \
		kubectl kustomize platform/postgres/manifests \
			| kubectl apply --dry-run=server -f - >/dev/null || exit 1; \
	else \
		kubectl kustomize platform/postgres/manifests >/dev/null || exit 1; \
		echo "   (CRD di CNPG o ns databases non ancora nel cluster: solo render kustomize)"; \
	fi
	@kubectl apply --dry-run=server -f bootstrap/root-app.yaml >/dev/null
	@kubectl apply --dry-run=server -f bootstrap/apps/ >/dev/null
	@echo "OK"

##@ ArgoCD

.PHONY: argo-apps
argo-apps: ## Elenco Application con sync/health
	@kubectl -n argocd get applications \
		-o custom-columns=APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revision

.PHONY: argo-sync
argo-sync: ## Forza il sync della Application APP (normalmente non serve)
	kubectl -n argocd patch application $(APP) --type merge \
		-p '{"operation":{"initiatedBy":{"username":"make"},"sync":{"revision":"HEAD"}}}'

.PHONY: argo-refresh
argo-refresh: ## Hard refresh: rilegge il repo senza aspettare il polling
	kubectl -n argocd annotate application $(APP) argocd.argoproj.io/refresh=hard --overwrite

.PHONY: argo-pass
argo-pass: ## Password admin iniziale della UI ArgoCD
	@kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d; echo

.PHONY: argo-logs
argo-logs: ## Log dell'application-controller (perché un sync non parte)
	kubectl -n argocd logs -f deploy/argocd-application-controller --tail=$(TAIL) \
		|| kubectl -n argocd logs -f sts/argocd-application-controller --tail=$(TAIL)

##@ Observability

.PHONY: obs
obs: ## Stato dello stack: pod e volumi del namespace monitoring
	@kubectl -n monitoring get pods -o wide
	@echo
	@kubectl -n monitoring get pvc

.PHONY: obs-pass
obs-pass: ## Password admin di Grafana (login su https://grafana.<tailnet>.ts.net)
	@kubectl -n monitoring get secret grafana-admin \
		-o jsonpath='{.data.admin-password}' | base64 -d; echo

.PHONY: obs-targets
obs-targets: ## Target di scrape down — la prima cosa da guardare se manca una metrica
	@kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/targets?state=active" \
		| python3 -c 'import json,sys; t=json.load(sys.stdin)["data"]["activeTargets"]; d=[x for x in t if x["health"] != "up"]; print(len(t), "target attivi,", len(d), "down"); [print("  ", x["labels"].get("job"), x["scrapeUrl"], x["lastError"]) for x in d]'

.PHONY: obs-pf
obs-pf: ## Port-forward di Prometheus su localhost:9090 (PromQL senza passare da Grafana)
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090

##@ Postgres (pg-shared, namespace databases)

PG_PRIMARY = $$(kubectl -n databases get pod -l cnpg.io/cluster=pg-shared,cnpg.io/instanceRole=primary -o name)

.PHONY: pg-status
pg-status: ## Cluster, database, ruoli, pod e volumi di pg-shared
	@kubectl -n databases get cluster,database,pods,pvc
	@echo
	@echo "ruoli: $$(kubectl -n databases get cluster pg-shared -o jsonpath='{.status.managedRolesStatus.byStatus}')"
	@echo
	@kubectl -n databases get cronjob,job

.PHONY: pg-psql
pg-psql: ## psql come superuser nel primary (DB=nome, default postgres)
	kubectl -n databases exec -it $(PG_PRIMARY) -c postgres -- psql -d $(DB)

.PHONY: pg-user
pg-user: ## Password del ruolo APP: sigilla roles/APP-sealed.yaml e apps/APP/db-sealed-secret.yaml
	$(call check-app)
	@scripts/pg-user.sh $(APP)

.PHONY: pg-backup
pg-backup: ## Lancia subito il CronJob di backup e ne segue i log
	@job=pg-backup-manual-$$(date +%s); \
	kubectl -n databases create job --from=cronjob/pg-backup $$job && \
	kubectl -n databases wait --for=condition=Ready pod -l job-name=$$job --timeout=120s >/dev/null; \
	kubectl -n databases logs -f job/$$job

.PHONY: pg-backups
pg-backups: ## Elenco dei dump sul volume pg-backups
	@kubectl -n databases run pg-backups-ls --rm -i --quiet --restart=Never --image=busybox:1.37 \
		--overrides='{"spec":{"containers":[{"name":"ls","image":"busybox:1.37","command":["sh","-c","cd /backups && du -sh 20* 2>/dev/null; ls -l 20*/ 2>/dev/null || echo nessun backup"],"volumeMounts":[{"name":"b","mountPath":"/backups"}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"pg-backups"}}]}}'

##@ Notifiche (notify-hub)

.PHONY: notify-vapid
notify-vapid: ## Chiave VAPID dell'hub, sigillata (rigenerarla invalida TUTTE le sottoscrizioni)
	@scripts/notify-vapid.sh

.PHONY: notify-token
notify-token: ## Token di APP per l'hub: sigilla apps/APP/notify-sealed-secret.yaml e scrive l'hash in NOTIFY_APPS
	$(call check-app)
	@scripts/notify-token.sh $(APP)

.PHONY: notify-subs
notify-subs: ## Dispositivi iscritti per app (dal DB notify)
	@kubectl -n databases exec -i $(PG_PRIMARY) -c postgres -- psql -d notify \
		-c "SELECT app, label, created_at, last_success_at, failures FROM subscriptions ORDER BY app, id;"

.PHONY: ghcr-pull
ghcr-pull: ## Pull secret GHCR per APP, risigillato da un namespace esistente (FROM=alfred)
	$(call check-app)
	@scripts/ghcr-pull.sh $(APP) $(or $(FROM),alfred)

##@ IoT (Zigbee2MQTT + GPU)

.PHONY: gpu-status
gpu-status: ## Presa della GPU (stato, watt), pop-os sulla tailnet, Ollama
	@scripts/gpu-power.sh status

.PHONY: gpu-on
gpu-on: ## Accende il PC con la GPU (presa ON) e aspetta che Ollama risponda
	@scripts/gpu-power.sh on

.PHONY: gpu-off
gpu-off: ## Shutdown pulito di pop-os via SSH, poi presa OFF quando i watt sono a zero
	@scripts/gpu-power.sh off

.PHONY: zigbee-pair
zigbee-pair: ## Apre il join della rete Zigbee per 2 minuti
	@kubectl -n iot exec deploy/mosquitto -c mosquitto -- sh -c \
		'mosquitto_pub -h localhost -u cli -P "$$CLI_PASSWORD" -t zigbee2mqtt/bridge/request/permit_join -m "{\"time\":120}"'
	@echo "join aperto per 120s: tieni premuto il tasto della presa ~5s finché il LED lampeggia"

.PHONY: iot-secrets
iot-secrets: ## Password MQTT (+ network key Zigbee al primo giro), sigillate in apps/iot/sealed-secret.yaml
	@scripts/iot-secrets.sh

##@ Secrets

.PHONY: seal
seal: ## Sigilla un .env in apps/APP/sealed-secret.yaml (ENV_FILE=path/to/.env)
	$(call check-app)
	@test -n "$(ENV_FILE)" || { echo "manca ENV_FILE=path/to/.env"; exit 1; }
	@test -f "$(ENV_FILE)" || { echo "$(ENV_FILE) non esiste"; exit 1; }
	kubectl create secret generic $(APP)-secrets -n $(NS) \
		--from-env-file=$(ENV_FILE) --dry-run=client -o yaml \
		| kubeseal --controller-namespace kube-system -o yaml \
		> apps/$(APP)/sealed-secret.yaml
	@echo "scritto apps/$(APP)/sealed-secret.yaml — rivedi il diff e committa"

.PHONY: litellm-key
# La master key non esce dal cluster: la chiamata parte da dentro il pod del
# proxy. Gli alias sono unici: un 400 di solito vuol dire che la chiave di APP
# esiste già (revocala dalla UI prima di crearne un'altra).
litellm-key: ## Crea una chiave virtuale LiteLLM per APP (BUDGET=dollari ogni 30gg, MODELS=a,b — vuoto = tutti)
	$(call check-app)
	@kubectl -n litellm exec deploy/litellm-proxy -- python -c "import os, json, urllib.request as u; \
		models = [m for m in '$(MODELS)'.split(',') if m]; \
		body = {'key_alias': '$(APP)', 'models': models, 'max_budget': float('$(BUDGET)'), 'budget_duration': '30d'}; \
		req = u.Request('http://localhost:4000/key/generate', data=json.dumps(body).encode(), \
			headers={'Authorization': 'Bearer ' + os.environ['LITELLM_MASTER_KEY'], 'Content-Type': 'application/json'}); \
		print(json.load(u.urlopen(req))['key'])"
	@echo "↑ chiave virtuale di $(APP): mettila come ANTHROPIC_API_KEY nel .env dell'app e risigilla"

.PHONY: litellm-rekey
litellm-rekey: ## Nuova chiave virtuale per APP e risigilla il suo secret (BUDGET, MODELS come litellm-key; KEY_VAR=nome variabile)
	$(call check-app)
	@scripts/litellm-rekey.sh $(APP) "$(MODELS)" $(BUDGET) $(KEY_VAR)

.PHONY: secrets
secrets: ## Secret decifrati presenti nel namespace di APP (solo i nomi)
	$(call check-app)
	@kubectl -n $(NS) get secrets
	@echo "--- chiavi di $(APP)-secrets ---"
	@kubectl -n $(NS) get secret $(APP)-secrets -o jsonpath='{range .data.*}{"\n"}{end}' >/dev/null 2>&1 \
		&& kubectl -n $(NS) get secret $(APP)-secrets -o go-template='{{range $$k, $$v := .data}}{{$$k}}{{"\n"}}{{end}}' \
		|| echo "(secret non ancora decifrato dal controller)"

.PHONY: seal-grafana
seal-grafana: ## Rigenera la password admin di Grafana (sigillata) — poi commit e push
	@test -n "$(GRAFANA_PW)" || { echo "manca GRAFANA_PW='...'"; exit 1; }
	kubectl create secret generic grafana-admin -n monitoring \
		--from-literal=admin-user=admin \
		--from-literal=admin-password="$(GRAFANA_PW)" \
		--dry-run=client -o yaml \
		| kubeseal --controller-namespace kube-system -o yaml \
		> platform/observability/manifests/grafana-admin-sealed-secret.yaml
	@echo "scritto platform/observability/manifests/grafana-admin-sealed-secret.yaml"
