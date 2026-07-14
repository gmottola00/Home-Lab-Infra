# Homelab infra — Minisforum UM790

Fondamenta condivise per le tue app (TickUp, Trip-AI) e, in futuro, per Jarvis.
Il mini PC e' l'hub always-on; il PC con la 5080 e' un worker di inferenza on-demand.

```
Internet  ──✗ (niente porte aperte sul router)
                        │
iPhone ──[Tailscale]────┤
                        ▼
   ┌─────────────────────────────────────────┐
   │  Minisforum UM790 (always-on)            │
   │   Caddy ── tickup ── trip-ai   (Docker)  │
   └──────────────┬──────────────────────────┘
                  │ tailnet + Wake-on-LAN
                  ▼
   ┌─────────────────────────────────────────┐
   │  PC fisso + RTX 5080  → Ollama (14B/7B)  │  (fase Jarvis)
   └─────────────────────────────────────────┘
```
Lo stato (DB) vive su **Supabase**: qui non gira Postgres.

## Struttura
```
infra/
  docker-compose.yml        caddy + tickup + trip-ai
  caddy/Dockerfile          Caddy + plugin DNS Cloudflare
  Caddyfile                 Opzione A (dominio) | Opzione B (solo tailnet)
  .env.example              CLOUDFLARE_API_TOKEN (solo Opzione A)
  secrets/*.env.example     secrets per app (Supabase, ecc.)
  examples/Dockerfile.fastapi  da copiare in ogni app
```
Si assume che i repo `tickup/` e `trip-ai/` stiano **accanto** a `infra/`
(`../tickup`, `../trip-ai`) e abbiano un Dockerfile (vedi esempio).

## Setup — una volta sola

### 1. Tailscale (la rete privata)
```bash
# sul mini PC
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ip -4          # annota l'IP 100.x.y.z del mini PC
```
- Installa **Tailscale** anche su iPhone (App Store) e sul PC-GPU. Stesso account.
- In admin console attiva **MagicDNS** → ogni macchina ha un nome `*.ts.net`.

### 2. Docker
```bash
curl -fsSL https://get.docker.com | sh
```

### 3. Secrets
```bash
cp secrets/tickup.env.example  secrets/tickup.env
cp secrets/trip-ai.env.example secrets/trip-ai.env
# compila con URL/chiavi Supabase
```

### 4. Scegli TLS nel Caddyfile
- **Opzione A (consigliata, hai un dominio):** scommenta il blocco A, metti i tuoi
  sottodomini, crea su Cloudflare i record A verso l'IP 100.x del mini PC (proxy OFF),
  `cp .env.example .env` e inserisci il token Cloudflare.
- **Opzione B (nessun dominio):** lascia il blocco B, sostituisci `minipc.CAMBIAMI.ts.net`
  col vero hostname MagicDNS. Aggiungi `ROOT_PATH=/tickup` e `/trip-ai` nei rispettivi .env.

### 5. Su
```bash
docker compose up -d --build
docker compose logs -f caddy      # controlla che i certificati salgano
```

### 6. App Flutter
Punta la base URL all'hostname finale (es. `https://tickup.tuodominio.com` o
`https://minipc.ts.net/tickup`). Con Tailscale attivo sull'iPhone funziona dentro
e fuori casa senza cambiare nulla.

## Wake-on-LAN (per la fase Jarvis)
Serve ad accendere il PC-GPU dal mini PC solo quando serve inferenza.
1. Nel BIOS del fisso: abilita **Wake-on-LAN / Power On by PCIe**.
2. Sul mini PC: `sudo apt install wakeonlan` poi `wakeonlan AA:BB:CC:DD:EE:FF`
   (MAC della scheda di rete del fisso).
3. Jarvis chiamera' questo prima di girare un modello locale, e potra' sospendere
   il fisso dopo N minuti di idle.

## Prossimi passi
- [ ] Infra su + due app raggiungibili da iPhone  ← siamo qui
- [ ] Ollama sul PC-GPU, esposto sulla tailnet
- [ ] Orchestratore Jarvis (routing locale/cloud) + MCP
- [ ] Interfaccia iOS (Shortcut "Hey Siri, chiedi a Jarvis" + Open WebUI PWA)
```
