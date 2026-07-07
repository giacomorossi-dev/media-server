# Backup del sistema

Procedura completa per configurare il backup **cifrato** delle configurazioni su cloud,
dalla A alla Z. Se cerchi solo il riassunto, è in [SETUP.md](./SETUP.md) §10.

## Cosa salviamo (e cosa no)

Salviamo i **volumi di configurazione** dei container:

| Volume | Contenuto |
|---|---|
| `mediaserver-jellyfin-config` | utenti, librerie, metadati, impostazioni Jellyfin |
| `mediaserver-radarr-config` · `-sonarr-config` | database film/serie, profili, root folder |
| `mediaserver-prowlarr-config` | indexer e credenziali |
| `mediaserver-bazarr-config` | impostazioni sottotitoli |
| `mediaserver-qbittorrent-config` | impostazioni client, categorie |

**Non** salviamo i film e le serie: sono grandi e ri-scaricabili, riempirebbero il cloud
per niente. Proteggiamo la *configurazione* — quella che costa ore a rifare.

**Strumento:** [restic](https://restic.net) — backup **cifrati** (fondamentale: i config
contengono API key e credenziali), **incrementali** (dopo il primo salva solo le
differenze) e con **retention** automatica.

**Destinazione consigliata: Cloudflare R2** — S3-compatibile (nessuna trafila OAuth), free
tier 10 GB, nessun costo di egress. Alternativa Google Drive (vedi §7).

---

## 1. Creare il bucket su Cloudflare R2

1. Vai su <https://dash.cloudflare.com> → **R2**.
2. Se è la prima volta, attiva R2. > ⚠️ Cloudflare richiede un **metodo di pagamento a
   registro** anche per restare nel free tier (non ti addebita nulla entro i limiti).
3. **Create bucket** → nome `mediaserver-backup`, location *Automatic* → crea.
4. Prendi nota dell'**Account ID** (in alto nella pagina R2): l'endpoint S3 sarà
   `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.

## 2. Creare il token di accesso

1. In **R2 → Manage R2 API Tokens → Create API Token**.
2. Permessi: **Object Read & Write**; opzionalmente limita il token al solo bucket
   `mediaserver-backup`.
3. Crea e **copia subito** *Access Key ID* e *Secret Access Key* (il secret si vede una
   volta sola).

## 3. File delle credenziali sul server

Genera una passphrase robusta per la cifratura:

```bash
openssl rand -base64 24
```

Crea il file (fuori dal repo, leggibile solo da root):

```bash
sudo tee /etc/mediaserver-backup.env >/dev/null <<'EOF'
export RESTIC_REPOSITORY="s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/mediaserver-backup"
export RESTIC_PASSWORD="LA_PASSPHRASE_GENERATA_SOPRA"
export AWS_ACCESS_KEY_ID="R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="R2_SECRET_ACCESS_KEY"
EOF
sudo chmod 600 /etc/mediaserver-backup.env
```

> 🔑 **Salva la passphrase in un password manager, separata dal server.** Senza di essa i
> backup cifrati sono **irrecuperabili** — nemmeno tu potrai leggerli.

## 4. Primo backup

```bash
sudo apt install -y restic
sudo ./scripts/backup-config.sh
```

Alla prima esecuzione lo script inizializza il repository restic, poi esegue il backup e
applica la retention. Output atteso: un nuovo *snapshot* con tag `config`.

## 5. Verificare

```bash
source /etc/mediaserver-backup.env
restic snapshots          # elenco dei backup
restic stats              # spazio occupato nel repository
restic check              # verifica l'integrità del repository
```

## 6. Automatizzare (timer systemd, adatto all'on-demand)

Un timer con `Persistent=true` esegue il backup **al primo avvio utile** se la macchina
era spenta all'orario previsto — perfetto per un server acceso a intermittenza.

```bash
sudo tee /etc/systemd/system/mediaserver-backup.service >/dev/null <<EOF
[Unit]
Description=Backup config media server (restic)

[Service]
Type=oneshot
ExecStart=$(pwd)/scripts/backup-config.sh
EOF

sudo tee /etc/systemd/system/mediaserver-backup.timer >/dev/null <<'EOF'
[Unit]
Description=Backup giornaliero config media server

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now mediaserver-backup.timer
```

Controlli:

```bash
systemctl list-timers | grep mediaserver-backup     # prossima esecuzione
journalctl -u mediaserver-backup.service            # log dell'ultimo backup
```

## 7. Alternativa: Google Drive (via rclone)

```bash
sudo apt install -y rclone restic
rclone config      # crea un remote "drive"
```

Su una macchina headless, quando `rclone config` chiede «Use auto config?» rispondi **No**
ed esegui `rclone authorize "drive"` da un PC con browser, poi incolla il token.

Nel file credenziali usa il backend rclone al posto dell'S3 (le chiavi AWS non servono):

```bash
export RESTIC_REPOSITORY="rclone:drive:mediaserver-backup"
export RESTIC_PASSWORD="LA_PASSPHRASE"
```

## 8. Ripristino

A stack spento, ripristina e reinserisci i dati nei volumi:

```bash
source /etc/mediaserver-backup.env
cd ~/media-server
docker compose down

sudo restic restore latest --target /tmp/restore

for v in jellyfin radarr sonarr prowlarr bazarr qbittorrent; do
  sudo rsync -a --delete \
    "/tmp/restore/var/lib/docker/volumes/mediaserver-$v-config/_data/" \
    "/var/lib/docker/volumes/mediaserver-$v-config/_data/"
done

docker compose up -d
sudo rm -rf /tmp/restore
```

## 9. Test di ripristino (importante)

> Un backup mai testato non è un backup. Ogni tanto verifica di riuscire davvero a
> leggerlo, ripristinando in una cartella temporanea senza toccare la produzione:

```bash
source /etc/mediaserver-backup.env
restic restore latest --target /tmp/restore-test
ls -R /tmp/restore-test | head        # controlla che i file ci siano
sudo rm -rf /tmp/restore-test
```

## 10. Homepage

Nella dashboard c'è la card **Backup** che apre la console R2 di Cloudflare per controllare
il bucket. Lo stato dei backup si verifica da CLI con `restic snapshots` (un job pianificato
non ha una pagina web da mostrare in un widget).

## Troubleshooting

| Sintomo | Causa / rimedio |
|---|---|
| `Fatal: unable to open config file` | Repository non ancora inizializzato: rilancia lo script (fa `restic init`) o esegui `restic init`. |
| `Access Denied` / errori S3 | Endpoint o chiavi R2 sbagliati; controlla `RESTIC_REPOSITORY` e i permessi «Object Read & Write» del token. |
| `permission denied` sui volumi | Lo script va eseguito con `sudo` (deve leggere `/var/lib/docker/volumes`). |
| Il timer non parte | `sudo systemctl enable --now mediaserver-backup.timer` e verifica con `systemctl list-timers`. |
