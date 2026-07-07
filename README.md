# Media Server v2

Stack self-hosted **locale** per scaricare e guardare film e serie TV, pensato per
un mini PC **acceso a domanda** (si accende, si scarica, si guarda, si spegne).

> 🛠️ Installazione del server da zero (Debian headless + hardening + Docker): vedi **[SETUP.md](./SETUP.md)**.
> 📋 Checklist interattiva end-to-end (da aprire nel browser): **[docs/install-guide.html](./docs/install-guide.html)**.

## Servizi

| Servizio | Porta | Ruolo |
|---|---|---|
| **Jellyfin** | 8096 | Streaming / riproduzione |
| **Radarr** | 7878 | Automazione film (ricerca → download → organizzazione) |
| **Sonarr** | 8989 | Automazione serie TV |
| **Prowlarr** | 9696 | Indexer (alimenta Radarr/Sonarr) |
| **Bazarr** | 6767 | Sottotitoli automatici |
| **qBittorrent** | 8080 | Download client (WebUI) |
| **Homepage** | 3000 | Dashboard con stato live dei servizi |

Container di supporto (senza porta web propria):
- **byparr** — bypassa il "Cloudflare challenge" per gli indexer pubblici protetti (usato da Prowlarr via `http://mediaserver-byparr:8191`).
- **backup-status** (`:8082`) — serve a Homepage la pagina di stato dei backup.

> **Nota rete (Italia):** molti tracker sono bloccati dal DNS dell'ISP (Piracy Shield). Per questo `byparr` e `qbittorrent` usano `dns: 1.1.1.1` nel compose, così risolvono l'IP reale. Contro un blocco anche per IP servirebbe una VPN.

Accesso da un browser sulla rete di casa: `http://IP_DEL_MINIPC:PORTA`
(la dashboard su `:3000` fa da lanciatore per tutti).

## Cosa è cambiato rispetto alla v1

- **Struttura a root unica `/data`** → import via *hardlink* invece di copie lente
  che raddoppiano lo spazio (era il difetto principale della v1).
- **Rimossi** Jackett (ridondante con Prowlarr) e la dashboard statica.
- **Aggiunti** Bazarr e Homepage.
- **Rimossa** la dipendenza dalla rete esterna `proxy-public`: accesso diretto via porte.
- **Versioni pinnate** (niente `:latest`), configurazione centralizzata in `.env`.

## Struttura delle cartelle (importante)

I media stanno su un **disco esterno** montato in `/mnt/media` (= `MEDIA_ROOT`). Il
montaggio persistente del disco (fstab, filesystem ext4) è descritto in
**[SETUP.md](./SETUP.md)**.

Perché gli hardlink funzionino, download e libreria devono stare **sotto un'unica
radice** — cioè sullo **stesso disco** — montata identica in ogni container:

```
/mnt/media                 (= MEDIA_ROOT = disco esterno, montato come /data)
├── torrents/              (qBittorrent scarica qui)
│   ├── movies/
│   └── tv/
└── media/                 (libreria Jellyfin; Radarr/Sonarr importano qui)
    ├── movies/
    └── tv/
```

Regole d'oro:
- **mai** montare `torrents/` e `media/` come volumi separati o su dischi diversi — è
  ciò che rompe gli hardlink e forza le copie;
- il disco va formattato **ext4**: exFAT non supporta gli hardlink, NTFS gestisce male
  i permessi Linux.

## Primo avvio

1. **Config**
   ```bash
   cp .env.example .env
   # modifica .env: SERVER_IP, HOMEPAGE_ALLOWED_HOSTS, MEDIA_ROOT
   # ricava i GID del server e mettili in .env:
   getent group docker    # -> DOCKER_GID
   getent group render    # -> RENDER_GID (solo se vuoi il transcoding HW)
   ```

2. **Prepara le cartelle** (il disco esterno dev'essere già montato — vedi SETUP.md)
   ```bash
   sudo mkdir -p /mnt/media/torrents/{movies,tv} /mnt/media/media/{movies,tv}
   sudo chown -R $USER:$USER /mnt/media
   ```
   > `PUID`/`PGID` nel `.env` devono coincidere col tuo utente (`id -u` / `id -g`):
   > così i file dei media sono tuoi e la cartella `homepage/` (clonata da te) è già
   > scrivibile dai container.

3. **Avvia**
   ```bash
   docker compose up -d
   ```

4. **Collega i servizi** (una tantum, dalle rispettive UI):
   - **qBittorrent** (`:8080`): login iniziale `admin` / password nel log
     (`docker logs mediaserver-qbittorrent | grep -i password`). Cambia la password.
     Imposta il percorso di download su `/data/torrents` e crea le categorie
     `movies` → `/data/torrents/movies`, `tv` → `/data/torrents/tv`.
   - **Prowlarr** (`:9696`): aggiungi gli indexer, poi *Settings → Apps* per
     collegare Radarr e Sonarr (push automatico degli indexer).
   - **Radarr** (`:7878`): *root folder* = `/data/media/movies`; download client
     = qBittorrent (host `mediaserver-qbittorrent`, porta `8080`), categoria `movies`.
   - **Sonarr** (`:8989`): *root folder* = `/data/media/tv`; download client come
     sopra, categoria `tv`.
   - **Bazarr** (`:6767`): collega Radarr e Sonarr (host `mediaserver-radarr` /
     `mediaserver-sonarr`), scegli le lingue dei sottotitoli.
   - **Jellyfin** (`:8096`): crea l'utente admin, aggiungi le librerie puntando a
     `/data/media/movies` e `/data/media/tv`.

5. **Widget Homepage** (opzionale): copia le API key di ogni app in `.env`
   (`*_API_KEY`) e la password di qBittorrent, poi `docker compose up -d homepage`.

## Migrazione dalla v1

La v1 usava `/mnt/media` (libreria) e `/mnt/media/downloads` (download). Vanno
riorganizzati nel nuovo layout. **Sono spostamenti sulla stessa partizione, quindi
istantanei** — ma fallo a stack spento e verifica prima cosa c'è dentro.

```bash
docker compose down                     # spegni la v1

mkdir -p /mnt/media/torrents /mnt/media/media/{movies,tv}

# 1) i download: da /mnt/media/downloads a /mnt/media/torrents
mv /mnt/media/downloads/* /mnt/media/torrents/ 2>/dev/null; rmdir /mnt/media/downloads

# 2) la libreria esistente: sposta film e serie sotto media/
#    ADATTA questi comandi ai nomi reali delle tue cartelle attuali!
#    es: mv "/mnt/media/Film" /mnt/media/media/movies  ...

sudo chown -R $USER:$USER /mnt/media
```

Dopo lo spostamento, in Radarr/Sonarr aggiorna la *root folder* alla nuova posizione
(`/data/media/...`) e fai un *rescan*. In Jellyfin ripunta le librerie a `/data/media/...`.

> Suggerimento: se hai spazio, fai prima un backup della struttura attuale
> (`ls -R /mnt/media > ~/media-layout-backup.txt`) così sai da dove parti.

## Transcoding hardware

Serve se un file non è in *direct play* sul client (codec non supportato). La iGPU
del Beelink EQR6 (Radeon 660M) usa **VAAPI**. Sul mini PC:

```bash
ls /dev/dri            # deve esserci renderD128
getent group render    # annota il GID
```

Il transcoding è **già attivo** nel `docker-compose.yml`: basta impostare `RENDER_GID`
nel `.env`. Poi in Jellyfin abilita *Dashboard → Playback → Hardware acceleration* =
**VAAPI**, device `/dev/dri/renderD128` (non «Quick Sync», che è solo Intel). Su hardware
senza iGPU, commenta il blocco `devices:`/`group_add:` del servizio `jellyfin`.

## qBittorrent: limitare il seeding (niente VPN)

Senza VPN conviene stare nello swarm il meno possibile. In qBittorrent →
*Options → BitTorrent*:
- **Seeding Limits**: ratio massimo `1.0` **oppure** tempo di seeding ~`60` minuti.
- Al raggiungimento: **Pause** (o Remove) del torrent.

Così, appena scaricato, esci in fretta dalla condivisione.

## Aggiungere una VPN in futuro (opzionale)

Se un giorno vuoi cifrare il traffico torrent, lo standard è **Gluetun**: si aggiunge
un container VPN e si mette qBittorrent in `network_mode: service:gluetun` (con
kill-switch integrato). Nessuna riristrutturazione del resto dello stack.

## Uso quotidiano (macchina on-demand)

La configurazione si fa **una volta sola**. Dopo, grazie a `restart: unless-stopped`:

- **Accendi il mini PC** → il demone Docker riparte e i container si riavviano da soli.
  **Non serve rilanciare `docker compose`**: apri il browser e usi i servizi.
- **Spegni** normalmente il mini PC quando hai finito.

Puoi anche accendere/spegnere **dal telefono** (Wake-on-LAN + SSH): vedi [SETUP.md](./SETUP.md) §11.

Rilanci `docker compose up -d` **solo** quando cambi la configurazione (`.env`,
`docker-compose.yml`, file di `homepage/`) o aggiorni le versioni delle immagini.

## Backup

Le configurazioni delle app (volumi `*-config`) vengono salvate **cifrate su cloud** con
`scripts/backup-config.sh` (restic → Cloudflare R2 o Google Drive). Il backup parte
**automaticamente a ogni accensione** (con guardia anti-doppioni) e il suo esito è visibile
nella card **Backup** di Homepage (lista completa su `http://IP:8082`). I **media non**
vengono salvati (usa-e-getta). Procedura completa: **[BACKUP.md](./BACKUP.md)**.

## Comandi utili

```bash
docker compose up -d           # avvia
docker compose down            # ferma
docker compose pull            # scarica gli aggiornamenti delle immagini pinnate
docker compose logs -f SERVIZIO
```

Aggiornare le versioni: modifica i tag immagine nel `docker-compose.yml`, poi
`docker compose pull && docker compose up -d`.
