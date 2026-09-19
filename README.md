# Argon NixOS home server

Argon is a low-power home server with one NVMe system disk and two mirrored
HDDs.

## Storage

| Device                   | Stable ID                                       | Use                         |
| ------------------------ | ----------------------------------------------- | --------------------------- |
| 1 TB WD Black SN850 NVMe | `nvme-WD_BLACK_SN850_Heatsink_1TB_21490K485613` | NixOS and application state |
| 2 TB Seagate HDD         | `ata-ST2000VX017-3CV102_WWD1ZSNZ`               | RAID1 member                |
| 2 TB Seagate HDD         | `ata-ST2000VX017-3CV102_WWD37CTW`               | RAID1 member                |

`hosts/argon/disko.nix` manages only the NVMe. The HDDs form an mdadm RAID1
with an ext4 filesystem labelled `ARGON_DATA`, mounted at `/srv/storage`.

The NVMe is unencrypted for unattended boot. Reinstalling it erases application
state under `/var`. RAID1 survives one disk failure but is not a backup.

## Recovery model

| Source | Authority for | Recovery action |
| --- | --- | --- |
| Git repository plus `flake.lock` | NixOS and declarative defaults | Install and rebuild the host |
| Restic `argon-system` | Host identity, secrets, automations, and application settings on the NVMe | Restore while recovery mode is active |
| RAID and Restic `argon-data` | Documents, photos, media, library data, and database dumps | Preserve the RAID, or restore it if the RAID was lost |

Keep reusable settings in Nix and secrets in root-only files. The Nix store,
caches, logs, and live databases are rebuilt or restored from dumps. Commit
`flake.lock`; do not change `system.stateVersion` for a reinstall.

## Installation

Boot a NixOS 26.05 ISO in UEFI mode and become root:

```sh
sudo -i
ping -c 3 nixos.org
git clone <THIS_REPO_URL> /tmp/argon
cd /tmp/argon
```

### 1. Evaluate the configuration

```sh
test -f flake.lock
nix --extra-experimental-features "nix-command flakes" \
  flake check --no-build
```

If `flake.lock` is missing, generate and commit it before installing.

### 2. Verify every disk

Confirm that all three links resolve to the expected disks:

```sh
ls -l /dev/disk/by-id/nvme-WD_BLACK_SN850_Heatsink_1TB_21490K485613
ls -l /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ
ls -l /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,MOUNTPOINTS
```

The HDD IDs must resolve to whole disks, not partitions.

### 3. Erase and mount the NVMe

The following command destroys the configured NVMe:

```sh
nix --extra-experimental-features "nix-command flakes" \
  --option http-connections 1 \
  --option http2 false \
  --option download-attempts 500 \
  run .#disko -- \
  --mode destroy,format,mount \
  ./hosts/argon/disko.nix

findmnt -R /mnt
```

### 4. Prepare the data RAID

#### Preserve an existing RAID

Check whether the installer assembled it automatically:

```sh
cat /proc/mdstat
lsblk -f
```

If it is absent, assemble it:

```sh
mdadm --assemble --scan
```

If scanning does not find it, assemble the known members explicitly:

```sh
mdadm --assemble /dev/md/argon-data \
  /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ \
  /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW
```

If assembly fails, stop and inspect both members with `mdadm --examine`.

```sh
blkid | grep ARGON_DATA
mkdir -p /mnt/srv/storage
mount /dev/disk/by-label/ARGON_DATA /mnt/srv/storage
findmnt /mnt/srv/storage
```

If the label differs, verify the filesystem before changing its label or
updating `hosts/argon/storage.nix`.

#### Create or replace the RAID

This irreversibly destroys both HDDs. Recheck their stable IDs first.

For blank disks, skip to the inspection commands. To replace an array, clear
both members first:

```sh
findmnt /dev/md/argon-data || true
# Run this only if the previous command shows /mnt/srv/storage:
umount /mnt/srv/storage

mdadm --stop /dev/md/argon-data
mdadm --zero-superblock --force \
  /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ
mdadm --zero-superblock --force \
  /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW
wipefs --all --force \
  /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ
wipefs --all --force \
  /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW
udevadm settle
```

Confirm both disks are blank:

```sh
wipefs -n /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ
wipefs -n /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW
mdadm --examine /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ || true
mdadm --examine /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW || true
```

Create and mount the RAID:

```sh
./scripts/create-data-raid.sh \
  /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ \
  /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW \
  --i-understand-this-erases-both-disks

mkdir -p /mnt/srv/storage
mount /dev/disk/by-label/ARGON_DATA /mnt/srv/storage
findmnt /mnt/srv/storage
cat /proc/mdstat
```

### 5. Install NixOS

Copy the repository to the target and install:

```sh
mkdir -p /mnt/etc/nixos
rsync -a --delete /tmp/argon/ /mnt/etc/nixos/
cd /mnt/etc/nixos
test -f flake.lock

nixos-install --flake .#argon \
  --option http-connections 1 \
  --option http2 false \
  --option download-attempts 500
```

Set the initial `argon` password:

```sh
nixos-enter --root /mnt -c 'passwd argon'
```

### 6. Choose how this installation starts

#### Start as a new server

```sh
reboot
```

#### Continue a previous installation

Create the recovery marker before the first boot:

```sh
install -D -m 0600 /dev/null /mnt/var/lib/argon-recovery-mode
```

The marker keeps applications, automations, dumps, and Restic jobs stopped
during recovery.

Create a new Storage Box SSH key. Replace both example values:

```sh
storage_box_user=uXXXXX-subX
storage_box_host=uXXXXX-subX.your-storagebox.de
secret_dir=/mnt/var/lib/argon-secrets

umask 077
install -d -m 0700 "$secret_dir"
ssh-keygen -t ed25519 -N '' -f "$secret_dir/restic-ssh-key"
ssh-keyscan -p 23 -t ed25519 "$storage_box_host" \
  > "$secret_dir/restic-known-hosts"
chmod 0600 "$secret_dir/restic-known-hosts"
ssh-keygen -lf "$secret_dir/restic-known-hosts"
```

Verify Hetzner's published ED25519 fingerprint:

```text
SHA256:XqONwb1S0zuj5A1CDxpOSuD2hnAArV1A3wKY7Z3sdgM
```

Authorize the key and recreate the Restic credential files:

```sh
ssh-copy-id -p 23 -s \
  -i "$secret_dir/restic-ssh-key.pub" \
  -o UserKnownHostsFile="$secret_dir/restic-known-hosts" \
  -o GlobalKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=yes \
  "$storage_box_user@$storage_box_host"

install -m 0600 /dev/null "$secret_dir/restic-password"
read -rsp 'Existing Restic password: ' restic_password; echo
printf '%s\n' "$restic_password" > "$secret_dir/restic-password"
unset restic_password

printf 'sftp://%s@%s:23/restic/argon-system\n' \
  "$storage_box_user" "$storage_box_host" \
  > "$secret_dir/restic-system-repository"
printf 'sftp://%s@%s:23/restic/argon-data\n' \
  "$storage_box_user" "$storage_box_host" \
  > "$secret_dir/restic-data-repository"
chmod 0600 "$secret_dir/restic-"*
unset secret_dir storage_box_user storage_box_host
```

Restore the latest NVMe snapshot to a staging directory. `/etc/nixos` and the
new Storage Box credentials are not overwritten:

```sh
nixos-enter --root /mnt -c 'restic-argon-system snapshots --latest 3'
nixos-enter --root /mnt -c \
  'set -eu
   restore_root=/var/tmp/argon-system-restore
   if test -e "$restore_root"; then
     echo "Refusing to reuse existing restore staging: $restore_root" >&2
     exit 1
   fi
   install -d -m 0700 "$restore_root"
   restic-argon-system restore latest \
     --target "$restore_root" \
     --exclude /etc/nixos'
```

Copy the persistent state into the installation:

```sh
nixos-enter --root /mnt -c \
  'set -eu
   restore_root=/var/tmp/argon-system-restore
   for path in \
     /etc/ssh \
     /home/argon/automation \
     /var/lib/argon-secrets \
     /var/lib/grimmory \
     /var/lib/immich \
     /var/lib/jellyfin \
     /var/lib/navidrome \
     /var/lib/netbird \
     /var/lib/paperless \
     /var/lib/qBittorrent \
     /var/lib/samba
   do
     source="$restore_root$path"
     if test -e "$source"; then
       rsync -aHAX --numeric-ids "$source" "$(dirname "$path")/"
     fi
   done
   test -f /var/lib/argon-recovery-mode
   test -f /var/lib/argon-secrets/restic-password
   rm -rf --one-file-system "$restore_root"'
```

If the RAID was preserved, do **not** restore `argon-data` over it. Otherwise,
restore it:

```sh
nixos-enter --root /mnt -c 'restic-argon-data snapshots --latest 3'
nixos-enter --root /mnt -c \
  'restic-argon-data restore latest --target /'
```

Leave the recovery marker in place and boot:

```sh
sync
reboot
```

## First boot

Verify the system, bridge, storage, and integrated GPU:

```sh
systemctl --failed
networkctl status br0
bridge link
findmnt /srv/storage
cat /proc/mdstat
readlink -f /dev/dri/argon-igpu
vainfo --display drm --device /dev/dri/argon-igpu
```

`br0` contains `enp2s0` through `enp5s0`. Connect only one port to the upstream
LAN; the other ports act as a software switch.

### Finish a continued installation

Confirm that recovery mode is active and the database dumps are present:

```sh
sudo test -f /var/lib/argon-recovery-mode
sudo ls -lh /srv/storage/backups/postgresql/*.sql.zstd
```

Restore the PostgreSQL databases:

```sh
sudo test -s /srv/storage/backups/postgresql/immich.sql.zstd
sudo test -s /srv/storage/backups/postgresql/paperless.sql.zstd

sudo -u postgres dropdb --if-exists immich
sudo -u postgres sh -c \
  'zstd -dc /srv/storage/backups/postgresql/immich.sql.zstd | psql --set=ON_ERROR_STOP=1 --dbname=postgres'

sudo -u postgres dropdb --if-exists paperless
sudo -u postgres sh -c \
  'zstd -dc /srv/storage/backups/postgresql/paperless.sql.zstd | psql --set=ON_ERROR_STOP=1 --dbname=postgres'
```

If Grimmory was configured, restore its latest MariaDB dump:

```sh
grimmory_dump="$(sudo sh -c \
  'ls -1t /srv/storage/backups/grimmory/grimmory-*.sql.zst | head -n 1')"
test -n "$grimmory_dump"

sudo systemctl start podman-grimmory-db.service
sudo podman exec grimmory-db sh -c \
  'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb -u root -e "DROP DATABASE IF EXISTS grimmory; CREATE DATABASE grimmory"'
sudo zstd -dc "$grimmory_dump" \
  | sudo podman exec -i grimmory-db sh -c \
      'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mariadb -u root grimmory'
unset grimmory_dump
```

Check the imported databases:

```sh
sudo -u postgres psql --dbname=immich \
  --command="select count(*) from pg_catalog.pg_tables where schemaname = 'public';"
sudo -u postgres psql --dbname=paperless \
  --command="select count(*) from pg_catalog.pg_tables where schemaname = 'public';"
```

After the checks succeed, retire the recovery marker and reboot:

```sh
sudo mv /var/lib/argon-recovery-mode \
  "/var/lib/argon-recovery-completed-$(date +%Y%m%d-%H%M%S)"
sudo reboot
```

After rebooting, check `systemctl --failed`, application logins, and the latest
Restic snapshots. If recovery fails, leave the marker in place.

### Accounts and remote access

On a new server, configure interactive credentials:

```sh
sudo netbird up
netbird status
sudo smbpasswd -a argon
sudo paperless-manage createsuperuser
```

Add your public SSH key, enable the key-only settings in
`hosts/argon/local.nix`, rebuild, and verify a second session before closing the
first.

Immich, Navidrome, and Grimmory create their first administrators through their
web interfaces.

### Grimmory secrets

On a new server, create Grimmory's environment files. Skip this after a restore:

```sh
sudo install -d -m 0700 /var/lib/argon-secrets
db_password="$(head -c 32 /dev/urandom | base64)"
root_password="$(head -c 32 /dev/urandom | base64)"

sudo install -m 0600 /dev/null /var/lib/argon-secrets/grimmory-app.env
printf 'DATABASE_PASSWORD=%s\n' "$db_password" \
  | sudo tee /var/lib/argon-secrets/grimmory-app.env >/dev/null

sudo install -m 0600 /dev/null /var/lib/argon-secrets/grimmory-db.env
printf 'MYSQL_PASSWORD=%s\nMYSQL_ROOT_PASSWORD=%s\n' \
  "$db_password" "$root_password" \
  | sudo tee /var/lib/argon-secrets/grimmory-db.env >/dev/null
unset db_password root_password

sudo systemctl restart podman-grimmory-db.service
sudo systemctl restart podman-grimmory.service
```

### Hetzner Storage Box backups

`hosts/argon/backup.nix` defines two encrypted Restic repositories:

- `argon-system`: selected NVMe configuration and application state. Stateful
  applications are stopped briefly for consistency.
- `argon-data`: `/srv/storage`, excluding replaceable downloads.

Both run daily.

On a new server, create a 5 TB Storage Box, enable external reachability and
SSH, and create a dedicated sub-account. Replace both example values:

```sh
storage_box_user=uXXXXX-subX
storage_box_host=uXXXXX-subX.your-storagebox.de

sudo install -d -m 0700 /var/lib/argon-secrets
sudo ssh-keygen -t ed25519 -N '' \
  -f /var/lib/argon-secrets/restic-ssh-key
```

Record and verify the Storage Box host key:

```sh
ssh-keyscan -p 23 -t ed25519 "$storage_box_host" \
  | sudo tee /var/lib/argon-secrets/restic-known-hosts >/dev/null
sudo chmod 0600 /var/lib/argon-secrets/restic-known-hosts
sudo ssh-keygen -lf /var/lib/argon-secrets/restic-known-hosts
```

It must match Hetzner's [published ED25519 fingerprint][hetzner-storage-box-host-keys]:

```text
SHA256:XqONwb1S0zuj5A1CDxpOSuD2hnAArV1A3wKY7Z3sdgM
```

After it matches, install the public key:

```sh
sudo ssh-copy-id -p 23 -s \
  -i /var/lib/argon-secrets/restic-ssh-key.pub \
  -o UserKnownHostsFile=/var/lib/argon-secrets/restic-known-hosts \
  -o GlobalKnownHostsFile=/dev/null \
  -o StrictHostKeyChecking=yes \
  "$storage_box_user@$storage_box_host"
```

Create a repository password. Save it, the Storage Box address, and account
recovery details outside this server:

```sh
sudo sh -c 'umask 077; head -c 48 /dev/urandom | base64 > /var/lib/argon-secrets/restic-password'
sudo cat /var/lib/argon-secrets/restic-password
```

Write the repository URLs:

```sh
sudo install -m 0600 /dev/null \
  /var/lib/argon-secrets/restic-system-repository
printf 'sftp://%s@%s:23/restic/argon-system\n' \
  "$storage_box_user" "$storage_box_host" \
  | sudo tee /var/lib/argon-secrets/restic-system-repository >/dev/null

sudo install -m 0600 /dev/null \
  /var/lib/argon-secrets/restic-data-repository
printf 'sftp://%s@%s:23/restic/argon-data\n' \
  "$storage_box_user" "$storage_box_host" \
  | sudo tee /var/lib/argon-secrets/restic-data-repository >/dev/null
unset storage_box_user storage_box_host
```

After rebuilding, run the first backups:

```sh
sudo systemctl start restic-backups-argon-system.service
sudo systemctl start restic-backups-argon-data.service
sudo journalctl -u restic-backups-argon-system -u restic-backups-argon-data -n 100

sudo restic-argon-system snapshots
sudo restic-argon-data snapshots
systemctl list-timers 'restic-backups-*'
```

Test restoration without writing over live data:

```sh
sudo install -d -m 0700 /tmp/argon-restic-restore
sudo restic-argon-system restore latest \
  --target /tmp/argon-restic-restore \
  --include /etc/nixos
sudo diff -r /etc/nixos /tmp/argon-restic-restore/etc/nixos
```

`/etc/nixos` in Restic is an emergency copy; Git remains authoritative.

Retain about seven daily Storage Box snapshots to protect Restic from deletion
by a compromised server.

[hetzner-storage-box-host-keys]: https://docs.hetzner.com/storage/storage-box/general/#ssh-host-keys

### qBittorrent, printing, and scanning

On a new server, replace qBittorrent's temporary password. Verify the printer
and scanner:

```sh
sudo journalctl -u qbittorrent -b | grep -i password
lpstat -t
scanimage -L
```

Send a scan to Paperless with one of:

```sh
sudo paperless-scan
sudo paperless-scan 'ADF Duplex'  # optional duplex scan
sudo paperless-scan Flatbed       # optional glass scan
```

## Updating the configuration

Review and build changes before activation. Git-backed flakes ignore untracked
files.

```sh
cd /etc/nixos
git pull --ff-only
git status --short
git diff
sudo nixos-rebuild build --flake .#argon
sudo nixos-rebuild dry-activate --flake .#argon
sudo nixos-rebuild test --flake .#argon
sudo systemctl --failed
sudo nixos-rebuild switch --flake .#argon
```

Apply network, SSH, kernel, initrd, and bootloader changes from a local console:

```sh
sudo nixos-rebuild boot --flake .#argon
sudo reboot
```

Roll back with `sudo nixos-rebuild switch --rollback`. Update inputs with
`nix flake update`, then build and test before switching.

## Health and backups

Check storage and power use:

```sh
cat /proc/mdstat
sudo mdadm --detail "$(findmnt -no SOURCE /srv/storage)"
sudo smartctl -a /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ
sudo smartctl -a /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW
sudo powertop
sudo turbostat --interval 5
```

Before erasing a working NVMe, refresh the database dumps and both Restic
repositories:

```sh
sudo systemctl start postgresqlBackup-immich.service
sudo systemctl start postgresqlBackup-paperless.service
sudo systemctl start grimmory-backup.service
sudo systemctl start restic-backups-argon-system.service
sudo systemctl start restic-backups-argon-data.service
sudo restic-argon-system snapshots --latest 1
sudo restic-argon-data snapshots --latest 1
```
