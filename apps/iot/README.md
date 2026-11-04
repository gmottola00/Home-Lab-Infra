# IoT: checklist dei passi manuali

Quello che Git e ArgoCD non possono fare da soli: pairing delle prese e setup
del PC con la GPU (`pop-os`). Una volta sola. Come funziona tutto il resto:
README principale, sezione "Zigbee e GPU".

> ⚠️ `homelab-plug` alimenta il nodo k3s: **non spegnerla mai**, né dalla UI
> né a mano. Il cluster cadrebbe e niente potrebbe riaccenderlo.

## 1. Zigbee2MQTT è partito

- [ ] `make ps`: i pod `mosquitto` e `zigbee2mqtt` in `iot` sono `Running`
- [ ] `make logs APP=iot COMP=zigbee2mqtt`: c'è `Zigbee2MQTT started`, nessun errore sulla seriale
- [ ] `https://zigbee.tail682dc3.ts.net` si apre (anche dall'iPhone)

## 2. Pairing delle prese

Per ciascuna delle due prese:

- [ ] `make zigbee-pair` (join aperto per 2 minuti)
- [ ] Tieni premuto il tasto della presa ~5 s finché il LED lampeggia
- [ ] Compare nella UI, sotto *Devices*

Poi dalla UI:

- [ ] Rinomina la presa del PC con la GPU in **`gpu-plug`** (deve essere esatto: lo usa `scripts/gpu-power.sh`)
- [ ] Rinomina la presa del nodo in **`homelab-plug`**
- [ ] *Power-on behavior* di `gpu-plug` → **off** (dopo un blackout la GPU non riparte da sola)
- [ ] *Power-on behavior* di `homelab-plug` → **on** (dopo un blackout il nodo riparte)
- [ ] Entrambe mostrano i watt

## 3. BIOS di pop-os

- [ ] *Restore on AC Power Loss* (o *AC Back*, *Power On After Power Fail*) → **Power On**

Così accendere la presa = accendere il PC.

## 4. SSH su pop-os (per lo spegnimento pulito)

La chiave è già sul nodo: `~/.ssh/gpu-poweroff` (privata, non si sposta) e
`~/.ssh/gpu-poweroff.pub` (pubblica, va su pop-os). Tutto questo si fa **su pop-os**.

- [ ] Server SSH (oggi la porta 22 rifiuta le connessioni):
  ```bash
  sudo apt install -y openssh-server
  sudo systemctl enable --now ssh
  ```
- [ ] Chiave autorizzata, limitata al solo spegnimento (niente shell, niente forwarding):
  ```bash
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  echo 'command="sudo /usr/bin/systemctl poweroff",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMtUmkHZEN1CZGh5z8sUKqQY8CFGhuaMdO7vqT5tjDZO gpu-poweroff' >> ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys
  ```
- [ ] Spegnimento senza password, solo per quel comando:
  ```bash
  echo "$USER ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff" | sudo tee /etc/sudoers.d/gpu-poweroff
  sudo chmod 440 /etc/sudoers.d/gpu-poweroff
  sudo visudo -c   # deve dire "parsed OK"
  ```
- [ ] `whoami` su pop-os: lo script usa `gm8la`; se cambia, `GPU_SSH_USER=<nome> make gpu-off`

> Qualsiasi connessione con questa chiave **spegne subito pop-os**, anche un
> `ssh ... true` di prova. Il test vero è il punto 5.

Se la chiave si perde o va cambiata: sul nodo
`ssh-keygen -t ed25519 -N "" -C gpu-poweroff -f ~/.ssh/gpu-poweroff` e
sostituisci la riga in `authorized_keys` su pop-os.

## 5. Prova end-to-end (dal nodo)

- [ ] `make gpu-status`: presa ON, watt alti, pop-os sulla tailnet, Ollama su
- [ ] `make gpu-off` (chiudi prima il lavoro aperto su pop-os): pop-os si spegne, i watt scendono, presa OFF
- [ ] `make gpu-on`: il PC parte e lo script finisce con `GPU pronta`
- [ ] Una chiamata a un modello `local/*` via LiteLLM risponde
