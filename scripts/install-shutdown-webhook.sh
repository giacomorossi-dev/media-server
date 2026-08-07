#!/usr/bin/env bash
# Installa/aggiorna il webhook di spegnimento gentile sul mini PC, in un colpo solo.
# Uso (SUL MINI PC, dalla cartella del repo, SENZA sudo):
#     bash scripts/install-shutdown-webhook.sh [IP_SHELLY]
# Esempio:
#     bash scripts/install-shutdown-webhook.sh 192.168.1.160
# Idempotente: puoi rilanciarlo; non rigenera il token, aggiorna solo cio' che serve.
set -euo pipefail

SHELLY_IP_ARG="${1:-}"

# --- utente di servizio (chi lancia, mai root) ------------------------------
if [ "$(id -u)" -eq 0 ]; then
  SVC_USER="${SUDO_USER:-root}"
else
  SVC_USER="$(id -un)"
fi
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE=/etc/mediaserver-shutdown.env

echo ">> Utente di servizio: $SVC_USER"
echo ">> Repo: $REPO_DIR"

# helper: imposta o aggiorna KEY=VALUE nell'env
set_env_kv() {
  local k="$1" v="$2"
  if sudo grep -qE "^${k}=" "$ENV_FILE" 2>/dev/null; then
    sudo sed -i "s|^${k}=.*|${k}=${v}|" "$ENV_FILE"
  else
    echo "${k}=${v}" | sudo tee -a "$ENV_FILE" >/dev/null
  fi
}
# helper: aggiungi KEY=VALUE solo se la chiave manca (non sovrascrive)
add_env_kv_if_missing() {
  local k="$1" v="$2"
  sudo grep -qE "^${k}=" "$ENV_FILE" 2>/dev/null || echo "${k}=${v}" | sudo tee -a "$ENV_FILE" >/dev/null
}

# --- 1) python3 -------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo ">> Installo python3"
  sudo apt-get update && sudo apt-get install -y python3
fi

# --- 2) script + unit systemd (con l'utente giusto) -------------------------
sudo install -m0755 "$REPO_DIR/scripts/shutdown-webhook.py" /usr/local/bin/mediaserver-shutdown-webhook
sudo sed "s/^User=.*/User=$SVC_USER/" "$REPO_DIR/systemd/mediaserver-shutdown.service" \
  | sudo tee /etc/systemd/system/mediaserver-shutdown.service >/dev/null

# --- 3) sudoers (con l'utente giusto), validato prima di installare ---------
TMP_SUDO="$(mktemp)"
sed "s/^giacomo /$SVC_USER /" "$REPO_DIR/systemd/mediaserver-shutdown.sudoers" > "$TMP_SUDO"
sudo visudo -cf "$TMP_SUDO"                       # se non valido, lo script si ferma qui
sudo install -m0440 -o root -g root "$TMP_SUDO" /etc/sudoers.d/mediaserver-shutdown
rm -f "$TMP_SUDO"

# --- 4) config: crea con token se non esiste --------------------------------
if [ ! -f "$ENV_FILE" ]; then
  sudo install -m0640 -o root -g "$SVC_USER" "$REPO_DIR/systemd/mediaserver-shutdown.env.example" "$ENV_FILE"
  sudo sed -i "s/^SHUTDOWN_TOKEN=.*/SHUTDOWN_TOKEN=$(openssl rand -hex 16)/" "$ENV_FILE"
  echo ">> Creato $ENV_FILE con token generato"
else
  echo ">> $ENV_FILE esiste: token invariato"
fi

# --- 4b) parametri Shelly (idempotenti) -------------------------------------
if [ -n "$SHELLY_IP_ARG" ]; then
  set_env_kv SHELLY_IP "$SHELLY_IP_ARG"
  echo ">> SHELLY_IP impostato a $SHELLY_IP_ARG"
fi
add_env_kv_if_missing SHELLY_SWITCH_ID 0
add_env_kv_if_missing SHELLY_USER admin
add_env_kv_if_missing SHELLY_PASSWORD ""
add_env_kv_if_missing CUT_DELAY_SECONDS 120

# leggo i valori con grep, NON sorgendo il file
PORT="$(sudo grep -E '^LISTEN_PORT=' "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')"; PORT="${PORT:-9977}"
TOKEN_NOW="$(sudo grep -E '^SHUTDOWN_TOKEN=' "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')"
SHELLY_NOW="$(sudo grep -E '^SHELLY_IP=' "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')"

# --- 5) firewall (best-effort: solo se ufw attivo) --------------------------
LAN_IF="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  SUBNET="$(ip -o -f inet addr show dev "$LAN_IF" scope global 2>/dev/null | awk '{print $4}' | head -1)"
  if [ -n "${SUBNET:-}" ]; then
    sudo ufw allow from "$SUBNET" to any port "$PORT" proto tcp >/dev/null 2>&1 || true
    echo ">> ufw: aperta porta $PORT da $SUBNET"
  fi
fi

# --- 6) (ri)avvia il servizio ----------------------------------------------
sudo systemctl daemon-reload
sudo systemctl enable mediaserver-shutdown.service >/dev/null 2>&1 || true
sudo systemctl restart mediaserver-shutdown.service

# --- 7) verifica automatica (DRY-RUN: NON spegne) ---------------------------
IP="$(ip -o -f inet addr show dev "$LAN_IF" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
DRY=""
for _ in 1 2 3 4 5; do
  DRY="$(curl -sS --max-time 6 "http://localhost:$PORT/shutdown?token=$TOKEN_NOW&dry=1" 2>/dev/null || true)"
  if [ -n "$DRY" ]; then break; fi
  sleep 1
done

cat <<EOF

====================================================================
 Servizio         : $(systemctl is-active mediaserver-shutdown.service)
 Shelly configurato: ${SHELLY_NOW:-(nessuno)}
 DRY-RUN          : ${DRY:-nessuna risposta}

 -> se DRY-RUN dice "Shelly raggiungibile=True", e' tutto pronto.

 URL SPEGNIMENTO (PC giu' pulito + Shelly stacca dopo 2 min):
   http://$IP:$PORT/shutdown?token=$TOKEN_NOW
 URL ACCENSIONE (rele' Shelly ON):
   http://${SHELLY_NOW:-IP_SHELLY}/rpc/Switch.Set?id=0&on=true
====================================================================
EOF
