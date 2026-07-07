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

## 7. Deploy dello stack v2

```bash
git clone https://github.com/giacomorossi-dev/media-server.git
cd media-server
git checkout v2

# cartelle a root unica (hardlink)
sudo mkdir -p /mnt/media/torrents/{movies,tv} /mnt/media/media/{movies,tv}
sudo chown -R $USER:$USER /mnt/media

cp .env.example .env
# compila .env: PUID/PGID = `id -u`/`id -g`, MEDIA_ROOT, SERVER_IP,
# HOMEPAGE_ALLOWED_HOSTS, RENDER_GID, DOCKER_GID
# poi decommenta devices/group_add nel blocco jellyfin del docker-compose.yml

docker compose up -d
```

Per la **configurazione delle app** e la **migrazione dei media** dalla v1 → [README](./README.md).

---

Fatto. D'ora in poi accendi il mini PC → i container ripartono da soli
(`restart: unless-stopped`), guardi, spegni. Rilanci `docker compose up -d` solo dopo
aver cambiato la configurazione o aggiornato le versioni.
