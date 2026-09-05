# Argon NixOS home server

Argon is a low-power home server built around a Topton C246 motherboard, an
Intel Core i3-9100T, its UHD 630 integrated GPU, one NVMe system disk, and two
mirrored HDDs.

## Storage

| Device                   | Stable ID                                       | Use                         |
| ------------------------ | ----------------------------------------------- | --------------------------- |
| 1 TB WD Black SN850 NVMe | `nvme-WD_BLACK_SN850_Heatsink_1TB_21490K485613` | NixOS and application state |
| 2 TB Seagate HDD         | `ata-ST2000VX017-3CV102_WWD1ZSNZ`               | RAID1 member                |
| 2 TB Seagate HDD         | `ata-ST2000VX017-3CV102_WWD37CTW`               | RAID1 member                |

`hosts/argon/disko.nix` manages only the NVMe. The HDDs form an mdadm RAID1
with an ext4 filesystem labelled `ARGON_DATA`, mounted at `/srv/storage` by
`hosts/argon/storage.nix`. `nixos-install`, boot, and rebuild operations do not
create or format the RAID.

The unencrypted NVMe can boot unattended. Erasing it also erases databases and
other state under `/var`, so copy anything needed before reinstalling. RAID1
survives one disk failure but is not a backup.

## Services

Immich, Paperless-ngx, Jellyfin, Navidrome, Grimmory, qBittorrent, Samba, CUPS,
NetBird, Epson printer/scanner, backups, and Python automations are declared
under `hosts/argon/` and `modules/`; their configuration is not duplicated here.

## Installation

Boot a NixOS 26.05 ISO in UEFI mode and become root:

```sh
sudo -i
ping -c 3 nixos.org
git clone <THIS_REPO_URL> /tmp/argon
cd /tmp/argon
```

### 1. Evaluate the configuration

`flake.lock` pins the exact input revisions used by this repository:

```sh
nix --extra-experimental-features "nix-command flakes" \
  flake check --no-build
```

### 2. Verify every disk

Do not continue until all three links resolve to the expected model, size, and
serial number:

```sh
ls -l /dev/disk/by-id/nvme-WD_BLACK_SN850_Heatsink_1TB_21490K485613
ls -l /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ
ls -l /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,MOUNTPOINTS
```

The HDD links must refer to whole disks, not `-part1` links.

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

Choose exactly one of the following paths.

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

If scanning cannot find it, use the two known members explicitly:

```sh
mdadm --assemble /dev/md/argon-data \
  /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ \
  /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW
```

Stop and inspect `mdadm --examine` if assembly fails.

Verify and mount the existing filesystem:

```sh
blkid | grep ARGON_DATA
mkdir -p /mnt/srv/storage
mount /dev/disk/by-label/ARGON_DATA /mnt/srv/storage
findmnt /mnt/srv/storage
```

The configuration expects the ext4 label `ARGON_DATA`. If it differs, confirm
the filesystem is the correct one before changing its label with `e2label` or
change `hosts/argon/storage.nix` to its existing UUID.

#### Create a new RAID or deliberately start over

This path irreversibly destroys everything on both HDDs. Recheck the stable IDs
and make sure no wanted data remains.

For brand-new blank disks, skip directly to the inspection below. To discard an
existing array, first unmount it if mounted, stop it, and clear both members:

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

Confirm both disks are now blank:

```sh
wipefs -n /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ
wipefs -n /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW
mdadm --examine /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ || true
mdadm --examine /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW || true
```

The guarded helper performs its own checks, asks for a typed confirmation, and
creates the RAID1 and ext4 filesystem:

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

Initial synchronization continues in the background.

### 5. Install NixOS

Copy the same evaluated tree, including `flake.lock`, to the target:

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

Set the initial `argon` password before rebooting:

```sh
nixos-enter --root /mnt -c 'passwd argon'
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

`br0` contains `enp2s0` through `enp5s0`; normally `enp2s0` is the uplink and
the other three are switch ports. Any of the four can be the uplink, but connect
only one to the upstream LAN. The temporary USB NIC `enp0s20f0u1` is excluded.
Because this is a software switch, downstream devices disconnect when Argon is
off or rebooting.

### Accounts and remote access

Complete the setup that requires interactive credentials:

```sh
sudo netbird up
netbird status
sudo smbpasswd -a argon
sudo paperless-manage createsuperuser
```

Password SSH is enabled only for bootstrap. Add your public key and enable the
key-only settings shown in `hosts/argon/local.nix`, rebuild, and verify a second
SSH session before closing the first.

Immich, Navidrome, and Grimmory create their first administrators through their
web interfaces.

### Grimmory secrets

Grimmory remains stopped until its two root-only environment files exist:

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

Do not add these files to Git; Nix expressions and the Nix store are not secret
storage.

### qBittorrent, printing, and scanning

Read qBittorrent's temporary first-login password, then replace it in the Web
UI. Verify the automatically configured Epson ET-3950 and scanner:

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

Sync the repository and evaluate changes before activation. Stage newly created
files because Git-backed flakes ignore untracked files.

```sh
cd /etc/nixos
git pull --ff-only
git status --short
git diff
sudo nixos-rebuild build --flake .#argon
sudo nixos-rebuild dry-activate --flake .#argon
```

`test` activates temporarily; `switch` makes the tested generation persistent:

```sh
sudo nixos-rebuild test --flake .#argon
sudo systemctl --failed
sudo nixos-rebuild switch --flake .#argon
```

Apply network, SSH, kernel, initrd, or bootloader changes from a local console
with:

```sh
sudo nixos-rebuild boot --flake .#argon
sudo reboot
```

Use `sudo nixos-rebuild switch --rollback` to roll back. Rebuilds never
repartition the NVMe or recreate the RAID; the disko and RAID creation commands
are installation-only. Update inputs deliberately with `nix flake update`, then
build and test before switching.

## Health and backups

Check storage and idle behavior with:

```sh
cat /proc/mdstat
sudo mdadm --detail "$(findmnt -no SOURCE /srv/storage)"
sudo smartctl -a /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ
sudo smartctl -a /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW
sudo powertop
sudo turbostat --interval 5
```

A failed RAID member is replaced and rebuilt with mdadm; the surviving member
must not be reformatted and the array must not be recreated. A `lost+found`
directory at the root of the ext4 RAID is normal.

Immich and Paperless database dumps and Grimmory/Navidrome backups are written
to `/srv/storage/backups`. Before erasing a working NVMe, run the on-demand
database jobs and separately back up any wanted state under `/var/lib`,
`/home/argon/automation`, `/etc/nixos`, and `/var/lib/argon-secrets`:

```sh
sudo systemctl start postgresqlBackup-immich.service
sudo systemctl start postgresqlBackup-paperless.service
sudo systemctl start grimmory-backup.service
```

The RAID itself still needs an independent backup for irreplaceable files.
