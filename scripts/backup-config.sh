#!/usr/bin/env bash
#
# Backup cifrato dei volumi di configurazione verso cloud (restic).
#
# Le credenziali stanno in un file NON versionato (default /etc/mediaserver-backup.env),
# vedi SETUP.md. Esegui con sudo (serve leggere /var/lib/docker/volumes):
#   sudo ./scripts/backup-config.sh
#
set -euo pipefail

ENV_FILE="${MEDIASERVER_BACKUP_ENV:-/etc/mediaserver-backup.env}"
if [ ! -r "$ENV_FILE" ]; then
  echo "Errore: manca il file credenziali $ENV_FILE (vedi SETUP.md)." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

VOLUMES=/var/lib/docker/volumes
# Espande i volumi mediaserver-*-config; fallisce chiaro se non ce ne sono.
shopt -s nullglob
PATHS=("$VOLUMES"/mediaserver-*-config/_data)
if [ ${#PATHS[@]} -eq 0 ]; then
  echo "Errore: nessun volume mediaserver-*-config trovato in $VOLUMES." >&2
  exit 1
fi

echo ">> Inizializzo il repository restic (solo la prima volta)"
restic cat config >/dev/null 2>&1 || restic init

echo ">> Backup dei config (${#PATHS[@]} volumi)"
restic backup --tag config "${PATHS[@]}"

echo ">> Retention: 7 giornalieri, 4 settimanali, 6 mensili"
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

echo ">> Completato. Ultimo snapshot:"
restic snapshots --tag config --latest 1
