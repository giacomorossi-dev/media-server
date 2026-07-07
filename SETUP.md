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

1. Scarica l'immagine **netinst ufficiale** di Debian stable da <https://www.debian.org/download>
   (link diretto: <https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/> →
   `debian-<versione>-amd64-netinst.iso`). Da Debian 12 in poi **include già il firmware
   non-free** (Wi-Fi AX200 / GPU AMD), quindi non serve nessuna immagine "unofficial".
   Verifica l'hash con lo `SHA256SUMS` nella stessa cartella.
2. Scrivi la ISO su USB. **Su Fedora, senza installare nulla:** apri *Dischi* (GNOME) →
   *"Ripristina immagine disco…"* → scegli la ISO. In alternativa `dd`, oppure
   [balenaEtcher](https://etcher.balena.io) (cross-piattaforma).
3. Nel BIOS del Beelink (<kbd>Canc</kbd>/<kbd>F7</kbd>): disabilita Secure Boot (e Fast Boot), avvia da USB.
   > Se la USB non compare nel menù di boot, quasi sempre non è avviabile: verifica da un PC con
   > `lsblk -f` che mostri `iso9660` + `vfat`, altrimenti riscrivila (GNOME Dischi / `dd`). Se compare
   > **due volte**, scegli la voce **«UEFI:»**.
4. Durante l'installazione:
   - lingua/tastiera Italiano, hostname `mediaserver`
   - password di **root vuota** → il primo utente diventa `sudo`
   - partizionamento guidato sull'**SSD interno** (⚠️ non il WD Red dei media) → schema **«Tutti i file in una partizione»** (Docker sta in `/var/lib/docker`: partizione unica = nessun `/var` separato che si riempie)
   - mirror: **Italia** → `deb.debian.org` se proposto; proxy HTTP **vuoto**
   - «Selezione software»: **deseleziona** il desktop/GNOME, tieni solo **SSH server** + utilità standard
   - **GRUB** (bootloader): rispondi **Sì**, installalo sull'SSD; poi togli la USB e riavvia

## 2. Primo accesso e IP fisso

```bash
ip -4 addr show scope global   # trova l'IP
ip link                        # trova il MAC (per la prenotazione DHCP)
```

Il comando `ip`/`ip link` qui sopra va eseguito **sul mini PC** (monitor ancora attaccato),
oppure puoi leggere l'IP dalla lista dispositivi DHCP del router.

**Prenotazione DHCP (IP fisso) — procedura:**

1. Dal mini PC annota **MAC** (`ip link` → `link/ether …`) e **indirizzo del router**
   (`ip route | grep default`).
2. Browser → indirizzo del router (es. `http://192.168.1.1`), login admin (spesso su
   un'etichetta sul router).
3. Sezione (il nome varia): Fritz!Box → *Rete locale → Rete → dispositivo → «Assegna
   sempre lo stesso IPv4»*; TP-Link → *Advanced → Network → DHCP Server → Address
   Reservation*; Netgear → *LAN Setup → Address Reservation*; router ISP → *Rete/LAN →
   DHCP → «IP statico» / «Prenotazione indirizzi» / «Associazione IP-MAC»*.
4. Riconosci il mini PC dall'hostname `mediaserver` o dal MAC, assegnagli l'IP fisso,
   **Salva/Applica**.
5. Sul mini PC: `sudo dhclient -r && sudo dhclient` (o `sudo reboot`); verifica con
   `ip -4 addr`.

> Se il router non supporta le prenotazioni, imposta l'IP statico su Debian in
> `/etc/network/interfaces` (blocco `iface … inet static` con `address`/`gateway`/
> `dns-nameservers`), scegliendo un IP **fuori** dal pool DHCP, poi
> `sudo systemctl restart networking`.

Da qui in poi lavori via SSH **dal portatile** e scolleghi monitor/tastiera:

```bash
ssh TUO_UTENTE@IP_DEL_MINIPC
```

> **Wi-Fi → Ethernet (consigliato per un server).** Cavo e Wi-Fi hanno MAC diversi:
> passando a Ethernet rifai la prenotazione DHCP per il **MAC dell'interfaccia cablata**,
> assegnandole lo **stesso IP** (così non tocchi `.env`). Il **Wake-on-LAN funziona solo
> su cavo**, quindi configura la Fase 16 dopo il passaggio (sull'interfaccia Ethernet). Lo
> stack Docker non cambia. **Qualsiasi presa Ethernet di casa va bene**, purché sulla
> stessa rete (non una Wi-Fi ospiti/VLAN separata): l'IP prenotato segue il dispositivo,
> non la presa.

### Passare da Wi-Fi a Ethernet (procedura)

Su un'installazione headless le porte Ethernet **non sono configurate**: non basta infilare
il cavo. Dal mini PC (o via SSH sul Wi-Fi):

```bash
# 1) alza le porte e trova quella collegata (Link detected: yes)
sudo apt install -y ethtool
for i in $(ls /sys/class/net | grep -E '^e'); do sudo ip link set "$i" up; done
for i in $(ls /sys/class/net | grep -E '^e'); do echo -n "$i: "; sudo ethtool "$i" 2>/dev/null | grep -i "link detected"; done
# 2) configura in DHCP quella collegata (es. enp2s0)
printf '\nallow-hotplug enp2s0\niface enp2s0 inet dhcp\n' | sudo tee -a /etc/network/interfaces
sudo ifup enp2s0
ip -4 addr show enp2s0        # verifica IP
ip link show enp2s0           # annota il MAC per la prenotazione
```

> **Debian 13:** se `ifup` non prende IP e `dhclient` dà «comando non trovato», installa il
> client DHCP — deprecato ma compatibile con ifupdown e senza conflitti:
> `sudo apt install -y isc-dhcp-client`, poi `sudo ifdown enp2s0; sudo ifup enp2s0`.
> (Evita `dhcpcd`: parte come demone e litiga con la configurazione Wi-Fi.)

> **Nessuna lucina sulla porta?** Il LED di link si accende solo con l'interfaccia "su":
> esegui prima `sudo ip link set enpXsY up`. Se resta spenta e `ethtool` dice
> `Link detected: no` → è il cavo/porta (riassesta il connettore, prova l'altra porta o un
> altro cavo, verifica che la presa del router sia viva).

Poi fai la **prenotazione DHCP sul MAC dell'Ethernet** (stesso IP). Nella lista dispositivi
del router vedrai **due voci `mediaserver`** (Wi-Fi + Ethernet, stesso hostname): scegli
quella **Ethernet**, riconoscibile dal MAC/IP. Infine, verificato che l'SSH sull'IP Ethernet
funziona: `sudo rfkill block wifi`.

## 3. Aggiornamenti e firmware

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y firmware-amd-graphics amd64-microcode curl git ca-certificates
```

Se un pacchetto firmware non si trova, abilita il componente `non-free-firmware`.
Questo snippet funziona sia su Debian 13+ (formato deb822) sia su Debian 12 (classico):

```bash
# Debian 13+ (/etc/apt/sources.list.d/debian.sources)
if [ -f /etc/apt/sources.list.d/debian.sources ]; then
  sudo sed -i '/^Components:/{/non-free-firmware/!s/$/ non-free-firmware/}' \
    /etc/apt/sources.list.d/debian.sources
fi
# Debian 12 (/etc/apt/sources.list)
if [ -f /etc/apt/sources.list ]; then
  sudo sed -i '/^deb .*debian/{/non-free-firmware/!s/$/ non-free-firmware/}' \
    /etc/apt/sources.list
fi
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
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

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

> (Opzionale) Preavviso guasti disco: `sudo apt install -y smartmontools` poi
> `sudo smartctl -H /dev/sdX` per un check rapido della salute (i media non li salviamo,
> ma sapere che il disco sta morendo è comodo).

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

I volumi `mediaserver-*-config` contengono tutte le impostazioni delle app: perderli
significa riconfigurare tutto. Li salviamo **cifrati** su cloud (Cloudflare R2 o Google
Drive) con [restic](https://restic.net), tramite `scripts/backup-config.sh`.

In sintesi:

```bash
sudo apt install -y restic
# crea le credenziali in /etc/mediaserver-backup.env (chmod 600), poi:
sudo ./scripts/backup-config.sh
```

📖 **Procedura completa e dettagliata** (creazione bucket R2, token, automazione con timer
systemd, ripristino e test): vedi **[BACKUP.md](./BACKUP.md)**.

## 11. Accensione da telefono (Wake-on-LAN) e sicurezza di rete

### Accendere e spegnere da telefono

**Accensione — Wake-on-LAN:**

1. Nel BIOS del Beelink abilita **Power On by PCI-E / Wake-on-LAN** (e disabilita
   "ErP/Deep Sleep" se presente, altrimenti blocca il WoL). Usa la **rete via cavo**: il
   WoL su Wi-Fi è inaffidabile.
2. Rendi persistente il WoL sulla scheda di rete:

   ```bash
   sudo apt install -y ethtool
   IFACE=$(ip -o -4 route show default | awk '{print $5}')
   sudo tee /etc/systemd/system/wol.service >/dev/null <<EOF
   [Unit]
   Description=Abilita Wake-on-LAN su $IFACE
   After=network-online.target

   [Service]
   Type=oneshot
   ExecStart=/usr/sbin/ethtool -s $IFACE wol g

   [Install]
   WantedBy=multi-user.target
   EOF
   sudo systemctl enable --now wol.service
   ```
3. Dal telefono usa un'app **"Wake on LAN"**: invia il *magic packet* al **MAC** del
   server (lo trovi con `ip link`) sulla LAN.

**Spegnimento — via SSH:** consenti lo spegnimento senza password e lancialo da un'app SSH
(Termius/JuiceSSH, con chiave):

```bash
echo "$USER ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff" | sudo tee /etc/sudoers.d/poweroff
sudo chmod 0440 /etc/sudoers.d/poweroff
```

Sul telefono salvi il comando `sudo systemctl poweroff`.

> Flusso tipico: accendo col magic packet → dopo ~5 min parte il backup → guardo →
> `sudo systemctl poweroff` dal telefono.

### Sicurezza di rete (solo-LAN)

I servizi **non hanno login**: la sicurezza si regge sul fatto che sono raggiungibili solo
dalla rete di casa. Quindi:

- Sul router **disattiva UPnP** e verifica che **non ci sia alcun port-forward** verso il
  mini PC: è ciò che impedisce l'esposizione accidentale su internet.
- `ufw` (§4.2) limita già SSH alla LAN; le porte dei servizi restano volutamente aperte in
  LAN. Un layer di autenticazione servirà **solo** il giorno che esponi il server da fuori.

---

Fatto. D'ora in poi accendi il mini PC → i container ripartono da soli
(`restart: unless-stopped`), guardi, spegni. Rilanci `docker compose up -d` solo dopo
aver cambiato la configurazione o aggiornato le versioni.
