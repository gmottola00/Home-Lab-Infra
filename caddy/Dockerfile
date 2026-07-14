# Caddy con il plugin DNS Cloudflare (necessario per l'Opzione A: certificati
# Let's Encrypt via DNS-01 su un dominio tuo, senza esporre la porta 80 a internet).
# Se usi solo l'Opzione B (tls internal) questo build funziona lo stesso.
FROM caddy:2-builder AS builder
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
