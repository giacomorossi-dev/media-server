#!/usr/bin/env bash
#
# Backup cifrato dei volumi di configurazione verso cloud (restic).
#
# - Le credenziali stanno in un file NON versionato (default /etc/mediaserver-backup.env).
# - Pensato per partire all'accensione (timer systemd, vedi BACKUP.md): salta se l'ultimo
#   backup andato a buon fine è più recente di ~20h (evita doppioni su più accensioni).
# - Scrive SEMPRE lo stato in $STATUS_DIR (status.json + index.html) per Homepage.
#
# Uso:  sudo ./scripts/backup-config.sh [--force]
#
set -uo pipefail

FORCE="${1:-}"
ENV_FILE="${MEDIASERVER_BACKUP_ENV:-/etc/mediaserver-backup.env}"
STATUS_DIR="${BACKUP_STATUS_DIR:-/var/lib/mediaserver-backup-status}"
MIN_INTERVAL_MIN=1200   # 20h

if [ ! -r "$ENV_FILE" ]; then
  echo "Errore: manca il file credenziali $ENV_FILE (vedi BACKUP.md)." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

mkdir -p "$STATUS_DIR"
STAMP="$STATUS_DIR/last-success"
HISTORY="$STATUS_DIR/history.tsv"

write_status() {   # $1=result  $2=snapshot  $3=size  $4=note
  local now; now="$(date '+%Y-%m-%d %H:%M')"
  cat > "$STATUS_DIR/status.json" <<JSON
{
  "last_run": "$now",
  "result": "$1",
  "snapshot": "${2:--}",
  "size": "${3:--}",
  "note": "${4:-}"
}
JSON
  printf '%s\t%s\t%s\t%s\n' "$now" "$1" "${2:--}" "${3:--}" >> "$HISTORY"
  render_html
}

render_html() {
  {
    cat <<'HTML'
<!doctype html><meta charset="utf-8"><title>Backup — Media Server</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
 body{font:16px system-ui,sans-serif;background:#10161d;color:#dfe7ee;margin:0;padding:2rem}
 h1{font-size:1.3rem;margin:0 0 1rem}
 table{border-collapse:collapse;width:100%;max-width:720px}
 th,td{padding:.5rem .7rem;text-align:left;border-bottom:1px solid #232d38;font-variant-numeric:tabular-nums}
 th{font-size:.72rem;text-transform:uppercase;letter-spacing:.06em;color:#6e7c8a}
 .ok{color:#7fe0c4;font-weight:700}.fail{color:#ff8a8a;font-weight:700}
 code{font-family:ui-monospace,monospace}
</style>
<h1>Backup delle configurazioni</h1>
<table><tr><th>Data</th><th>Esito</th><th>Snapshot</th><th>Dimensione</th></tr>
HTML
    # ultime 30 righe, più recenti in cima
    if [ -f "$HISTORY" ]; then
      tail -n 30 "$HISTORY" | tac | while IFS=$'\t' read -r d r s z; do
        cls="ok"; [ "$r" = "OK" ] || cls="fail"
        printf '<tr><td>%s</td><td class="%s">%s</td><td><code>%s</code></td><td>%s</td></tr>\n' \
          "$d" "$cls" "$r" "$s" "$z"
      done
    fi
    echo "</table>"
  } > "$STATUS_DIR/index.html"
}

# --- Guardia anti-doppioni (solo se non forzato) ---------------------------
if [ "$FORCE" != "--force" ] && [ -f "$STAMP" ] \
   && [ -n "$(find "$STAMP" -mmin "-$MIN_INTERVAL_MIN" 2>/dev/null)" ]; then
  echo "Backup saltato: ultimo successo < 20h fa (usa --force per forzare)."
  exit 0
fi

# --- Volumi da salvare -----------------------------------------------------
VOLUMES=/var/lib/docker/volumes
shopt -s nullglob
PATHS=("$VOLUMES"/mediaserver-*-config/_data)
if [ ${#PATHS[@]} -eq 0 ]; then
  write_status "FAIL" "-" "-" "nessun volume mediaserver-*-config trovato"
  echo "Errore: nessun volume mediaserver-*-config trovato in $VOLUMES." >&2
  exit 1
fi

# --- Init repo alla prima esecuzione ---------------------------------------
if ! restic cat config >/dev/null 2>&1; then
  if ! restic init; then
    write_status "FAIL" "-" "-" "restic init fallito (credenziali/endpoint?)"
    exit 1
  fi
fi

# --- Backup ----------------------------------------------------------------
echo ">> Backup dei config (${#PATHS[@]} volumi)"
OUT="$(restic backup --tag config "${PATHS[@]}" 2>&1)"; RC=$?
echo "$OUT"

SNAP="$(printf '%s\n' "$OUT" | grep -oE 'snapshot [0-9a-f]+ saved' | grep -oE '[0-9a-f]{8}' | head -1)"
SIZE="$(printf '%s\n' "$OUT" | grep -oE 'Added to the repository: [0-9.]+ [KMGT]?iB' | sed 's/Added to the repository: //' | head -1)"

if [ $RC -ne 0 ]; then
  write_status "FAIL" "${SNAP:--}" "${SIZE:--}" "restic backup rc=$RC"
  echo "Backup FALLITO (rc=$RC)." >&2
  exit 1
fi

# --- Retention (solo su successo) ------------------------------------------
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune >/dev/null 2>&1 || true

touch "$STAMP"
write_status "OK" "${SNAP:--}" "${SIZE:--}" ""
echo ">> Completato. Snapshot ${SNAP:--} (${SIZE:--})"
