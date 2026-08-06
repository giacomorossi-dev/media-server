#!/usr/bin/env bash
# Installa il webhook di spegnimento gentile sul mini PC, in un colpo solo.
# Uso (SUL MINI PC, dalla cartella del repo, SENZA sudo):
#     bash scripts/install-shutdown-webhook.sh
# Idempotente: puoi rilanciarlo, non sovrascrive il token gia' generato.
set -euo pipefail

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

# --- 4) config + token (genera solo se non esiste gia') ---------------------
if [ ! -f "$ENV_FILE" ]; then
  TOKEN="$(openssl rand -hex 16)"
  sudo install -m0640 -o root -g "$SVC_USER" "$REPO_DIR/systemd/mediaserver-shutdown.env.example" "$ENV_FILE"
  sudo sed -i "s/^SHUTDOWN_TOKEN=.*/SHUTDOWN_TOKEN=$TOKEN/" "$ENV_FILE"
  echo ">> Creato $ENV_FILE con token generato automaticamente"
else
  echo ">> $ENV_FILE esiste gia': lo lascio com'e' (token invariato)"
fi

# NB: leggo i valori con grep, NON sorgendo il file (una riga come
# POWEROFF_CMD=sudo systemctl poweroff eseguirebbe il comando!).
PORT="$(sudo grep -E '^LISTEN_PORT=' "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')"
PORT="${PORT:-9977}"
TOKEN_NOW="$(sudo grep -E '^SHUTDOWN_TOKEN=' "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')"

# --- 5) firewall (best-effort: solo se ufw attivo) --------------------------
if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  SUBNET="$(ip -o -f inet addr show scope global | awk '{print $4}' | head -1)"
  if [ -n "${SUBNET:-}" ]; then
    sudo ufw allow from "$SUBNET" to any port "$PORT" proto tcp || true
    echo ">> ufw: aperta porta $PORT da $SUBNET"
  fi
fi

# --- 6) avvia il servizio ---------------------------------------------------
sudo systemctl daemon-reload
sudo systemctl enable --now mediaserver-shutdown.service
sudo systemctl --no-pager status mediaserver-shutdown.service || true

# --- 7) stampa i comandi di test gia' pronti --------------------------------
IP="$(ip -o -f inet addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
cat <<EOF

====================================================================
 Installato e avviato.

 TEST DRY-RUN (NON spegne, verifica solo webhook+token):
   curl "http://localhost:$PORT/shutdown?token=$TOKEN_NOW&dry=1"

 SPEGNIMENTO VERO (spegne davvero il PC!):
   curl "http://localhost:$PORT/shutdown?token=$TOKEN_NOW"

 URL per la SCENA SHELLY (azione HTTP, poi attendi 2 min, poi spegni relE'):
   http://$IP:$PORT/shutdown?token=$TOKEN_NOW
====================================================================
EOF
