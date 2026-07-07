# Setup del server (da zero)

Installazione e messa in sicurezza del mini PC che ospita lo stack, dal sistema
operativo al deploy. Per la **configurazione delle app** (Radarr, Jellyfin, ecc.) e
la **migrazione dei dati** vedi il [README](./README.md).

- **Hardware:** Beelink EQR6 — AMD Ryzen 5 6600H, iGPU Radeon 660M (RDNA2), 24 GB, 500 GB NVMe
- **OS consigliato:** Debian stable, installazione **headless** (senza desktop)
- **Transcoding:** VAAPI (non QuickSync, che è solo Intel)

> **Modello di rischio.** È un server in **LAN dietro il router (NAT)**: finché non fai
> port-forwarding, da internet non ci arriva nessuno — il router è il firewall vero.
> L'hardening qui sotto è **difesa in profondità**, non il muro principale. Regola
> d'oro: **non inoltrare mai** le porte dei servizi sul router. Se un domani esponi il
> server da fuori, servirà un layer di autenticazione davanti alle app di gestione.

---

## 1. Installazione Debian (headless)

1. Scarica l'immagine **netinst con firmware incluso** (serve per Wi-Fi/GPU):
   <https://cdimage.debian.org/images/unofficial/non-free/images-including-firmware/>
2. Scrivi la ISO su una USB con [balenaEtcher](https://etcher.balena.io).
3. Nel BIOS del Beelink (<kbd>Canc</kbd>/<kbd>F7</kbd>): disabilita Secure Boot, avvia da USB.
4. Durante l'installazione:
   - lingua/tastiera Italiano, hostname `mediaserver`
   - password di **root vuota** → il primo utente diventa `sudo`
   - partizionamento guidato sull'**SSD di sistema** (⚠️ non toccare eventuali dischi dei media)
   - «Selezione software»: **deseleziona** il desktop, tieni solo **SSH server** + utilità standard

## 2. Primo accesso e IP fisso

```bash
ip -4 addr show scope global   # trova l'IP
ip link                        # trova il MAC (per la prenotazione DHCP)
```

Fissa l'IP con una **prenotazione DHCP nel router** (associa IP ↔ MAC). Da qui lavori via SSH:

```bash
ssh TUO_UTENTE@IP_DEL_MINIPC
```

## 3. Aggiornamenti e firmware

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y firmware-amd-graphics amd64-microcode curl git ca-certificates
```

Se un pacchetto firmware non si trova, abilita il componente `non-free-firmware`:

```bash
sudo sed -i 's/ main$/ main non-free-firmware/' /etc/apt/sources.list
sudo apt update
```

## 4. Hardening (essenziale, senza esagerare)

### 4.1 Accesso SSH a chiave — *la misura che conta di più*

Sul **portatile**:

```bash
ssh-keygen -t ed25519 -C "mediaserver"
ssh-copy-id TUO_UTENTE@IP_DEL_MINIPC
```

Verifica di entrare **senza password**, poi sul **server** disabilita password e root:

```bash
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sudo systemctl restart ssh
```

> ⚠️ Fallo solo **dopo** aver verificato il login con chiave, tenendo aperta una seconda
> sessione SSH, per non chiuderti fuori.

### 4.2 Firewall (ufw), aperto solo alla LAN

```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.1.0/24 to any port 22 proto tcp   # adatta la subnet
sudo ufw enable
```

> **Nota onesta:** Docker pubblica le porte dei container **direttamente in iptables**,
> quindi ufw **non le filtra**. Nel nostro caso va bene (le vuoi in LAN, il router le tiene
> fuori da internet). ufw qui protegge SSH e i servizi host.

### 4.3 Fail2ban (belt-and-suspenders)

```bash
sudo apt install -y fail2ban
sudo tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
sudo systemctl enable --now fail2ban
```

> Con l'accesso a sola chiave (4.1) il brute-force è già impossibile: Fail2ban serve
> soprattutto a tagliare il rumore nei log. Opzionale, ma innocuo.

### 4.4 Aggiornamenti di sicurezza automatici

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades   # rispondi "Sì"
```

Il riavvio automatico è disattivato di default: bene, così la macchina non si riavvia
da sola mentre guardi.

### 4.5 Ritocchi leggeri (opzionali)

```bash
# cap ai log di sistema
sudo mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=200M\n' | sudo tee /etc/systemd/journald.conf.d/size.conf
sudo systemctl restart systemd-journald

# TRIM settimanale SSD + meno swap (24 GB di RAM)
sudo systemctl enable --now fstrim.timer
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf
sudo sysctl --system

# (facoltativo) audit di sicurezza con punteggio
sudo apt install -y lynis && sudo lynis audit system
```

## 5. Docker

```bash
# repo ufficiale
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
| sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# rotazione log dei container (evita che riempiano il disco)
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
sudo systemctl restart docker

# docker senza sudo (poi esci e rientra dalla sessione)
sudo usermod -aG docker $USER
```

## 6. Driver VAAPI (transcoding)

```bash
sudo apt install -y mesa-va-drivers vainfo
sudo usermod -aG render,video $USER      # poi esci e rientra
vainfo --display drm --device /dev/dri/renderD128   # deve elencare VAProfileH264/HEVC

getent group render   # -> RENDER_GID  (per .env)
getent group docker   # -> DOCKER_GID  (per .env)
```

## 7. Disco esterno per i media

I media (e i download) stanno su un **disco esterno** montato in `/mnt/media`. Deve
essere formattato **ext4**: exFAT non supporta gli hardlink, NTFS gestisce male i
permessi Linux.

Identifica il disco e la sua partizione:

```bash
lsblk -f          # trova il device (es. /dev/sda1) e il filesystem attuale
```

> ⚠️ Se il disco contiene già dati e NON è ext4, salvali altrove: formattarlo li
> cancella. Se è **già ext4** con i tuoi media, salta la formattazione e vai all'fstab.

Formatta in ext4 (⚠️ cancella il disco — verifica il device giusto!):

```bash
sudo mkfs.ext4 -L media /dev/sdX1        # <-- metti il TUO device
```

Monta in modo persistente via UUID (sopravvive ai riavvii e al cambio di lettera):

```bash
sudo mkdir -p /mnt/media
UUID=$(sudo blkid -s UUID -o value /dev/sdX1)   # <-- il TUO device
echo "UUID=$UUID  /mnt/media  ext4  defaults,nofail,x-systemd.device-timeout=10  0  2" \
  | sudo tee -a /etc/fstab
sudo mount -a
sudo chown -R $USER:$USER /mnt/media
```

> `nofail` evita che il boot si blocchi se il disco è scollegato. **Tieni il disco
> sempre collegato** al mini PC: se non è montato all'avvio, i container scriverebbero
> nella cartella vuota sull'SSD invece che sul disco.

## 8. Deploy dello stack v2

```bash
git clone https://github.com/giacomorossi-dev/media-server.git
cd media-server
git checkout v2

# cartelle a root unica sul disco esterno (hardlink)
sudo mkdir -p /mnt/media/torrents/{movies,tv} /mnt/media/media/{movies,tv}
sudo chown -R $USER:$USER /mnt/media

cp .env.example .env
# compila .env: PUID/PGID = `id -u`/`id -g`, MEDIA_ROOT, SERVER_IP,
# HOMEPAGE_ALLOWED_HOSTS, RENDER_GID, DOCKER_GID
# poi decommenta devices/group_add nel blocco jellyfin del docker-compose.yml

docker compose up -d
```

Per la **configurazione delle app** e la **migrazione dei media** dalla v1 → [README](./README.md).

## 9. Strumenti opzionali (cosa serve e cosa no)

Onestamente, per questo setup non serve molto altro. La regola: aggiungi solo ciò che
usi davvero, ogni container è superficie in più da mantenere.

- **Portainer** — GUI di gestione Docker (avvia/ferma container, log, exec). **Non
  necessario**: gestisci lo stack con `docker compose` da terminale e vedi lo stato in
  Homepage. Ha inoltre pieno controllo sul demone Docker (= root), quindi è anche
  superficie di rischio. Aggiungilo solo se preferisci cliccare invece di usare SSH.
- **Homepage** ≠ Portainer: è una **dashboard** (lanciatore + widget di stato), non
  gestisce i container. Per il tuo uso è sufficiente.
- **Backup dei config** (consigliato) — vedi sotto. È l'aggiunta che vale di più.
- **Dozzle** — visore di log dei container nel browser, leggero. Opzionale, se vuoi i
  log senza SSH.
- Da **evitare** qui: *Watchtower* (auto-update: può rompere i media server),
  *Diun/Uptime Kuma* (notifiche/monitoraggio: inutili su una macchina spenta gran
  parte del tempo).

## 10. Backup dei config su cloud (consigliato)

I volumi `mediaserver-*-config` contengono tutte le impostazioni delle app (comprese API
key e credenziali): perderli significa riconfigurare tutto. Li salviamo **cifrati** su
cloud con [restic](https://restic.net). Destinazione consigliata: **Cloudflare R2**
(S3-compatibile, free tier 10 GB, niente costi di egress). In alternativa Google Drive.

```bash
sudo apt install -y restic
```

### 10a. Preparare la destinazione — Cloudflare R2 (consigliato)

1. Nel dashboard Cloudflare → **R2** → crea un bucket, es. `mediaserver-backup`.
2. **R2 → Manage API Tokens** → crea un token: ottieni *Access Key ID*, *Secret Access
   Key* e l'endpoint `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.

Crea il file credenziali (fuori dal repo, leggibile solo da root):

```bash
sudo tee /etc/mediaserver-backup.env >/dev/null <<'EOF'
export RESTIC_REPOSITORY="s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/mediaserver-backup"
export RESTIC_PASSWORD="UNA_PASSPHRASE_ROBUSTA_PER_LA_CIFRATURA"
export AWS_ACCESS_KEY_ID="R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="R2_SECRET_ACCESS_KEY"
EOF
sudo chmod 600 /etc/mediaserver-backup.env
```

> ⚠️ Annota la `RESTIC_PASSWORD` in un posto sicuro: senza quella i backup sono
> **irrecuperabili** (sono cifrati).

### 10b. Alternativa — Google Drive (via rclone)

```bash
sudo apt install -y rclone
rclone config    # crea un remote tipo "drive"; su headless: rclone authorize da un PC con browser
```

Poi nel file credenziali usa il backend rclone invece dell'S3:

```bash
export RESTIC_REPOSITORY="rclone:drive:mediaserver-backup"
export RESTIC_PASSWORD="UNA_PASSPHRASE_ROBUSTA"
```

### 10c. Eseguire il backup

Lo script `scripts/backup-config.sh` inizializza il repo alla prima esecuzione, salva i
volumi di config e applica la retention (7 giornalieri / 4 settimanali / 6 mensili):

```bash
sudo ./scripts/backup-config.sh
```

> È un backup «a caldo» (stack acceso): per i DB SQLite delle app va bene nella quasi
> totalità dei casi. Per un backup 100% consistente, `docker compose stop` prima e
> `docker compose start` dopo.

### 10d. Automatizzarlo (opzionale, adatto all'on-demand)

Un timer systemd con `Persistent=true` esegue il backup **al primo avvio utile** se la
macchina era spenta all'orario previsto:

```bash
sudo tee /etc/systemd/system/mediaserver-backup.service >/dev/null <<EOF
[Service]
Type=oneshot
ExecStart=$(pwd)/scripts/backup-config.sh
EOF

sudo tee /etc/systemd/system/mediaserver-backup.timer >/dev/null <<'EOF'
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF

sudo systemctl enable --now mediaserver-backup.timer
```

### 10e. Ripristino

```bash
source /etc/mediaserver-backup.env
restic snapshots                 # elenca i backup
restic restore latest --target /tmp/restore   # poi copia i _data nei volumi, a stack spento
```

---

Fatto. D'ora in poi accendi il mini PC → i container ripartono da soli
(`restart: unless-stopped`), guardi, spegni. Rilanci `docker compose up -d` solo dopo
aver cambiato la configurazione o aggiornato le versioni.
