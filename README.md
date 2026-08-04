# Argon NixOS home server

Argon is a reproducible NixOS 26.05 configuration for a small home server. It
runs file, photo, media, download, printing, VPN, and Python automation services
for the `argon` user. Low idle power is a core design goal, without trading
away storage integrity or unattended operation.

## Hardware and storage

| Device | Stable ID | Purpose |
| --- | --- | --- |
| 1 TB WD Black SN850 NVMe | `nvme-WD_BLACK_SN850_Heatsink_1TB_21490K485613` | NixOS, applications, databases, caches, and user state |
| 2 TB Seagate HDD | `ata-ST2000VX017-3CV102_WWD1ZSNZ` | First RAID1 member |
| 2 TB Seagate HDD | `ata-ST2000VX017-3CV102_WWD37CTW` | Second RAID1 member |

The NVMe uses Btrfs subvolumes for `/`, `/nix`, `/var`, and `/home`. It is not
encrypted, allowing the server to restart unattended after a power failure.

The two HDDs form an mdadm RAID1 with an ext4 filesystem labelled
`ARGON_DATA`, mounted at `/srv/storage`. This provides about 2 TB of usable,
mirrored storage. The RAID and OS disk are deliberately independent:

- `hosts/argon/disko.nix` manages only the NVMe.
- Normal boots assemble the existing RAID and mount it by filesystem label.
- `nixos-rebuild` never creates or formats the RAID.
- `scripts/create-data-raid.sh` is the only RAID creation path.

This separation lets the NVMe be reinstalled without formatting the HDDs.
RAID1 protects against one failed disk; it does not replace a backup. Service
databases and metadata under `/var` are also lost when the NVMe is erased unless
they are backed up first.

The host uses an Intel Core i3-10100 and Intel Arc A380. The Arc render node is
available to Immich and configured for Jellyfin Quick Sync transcoding.

## Services

| Service | LAN or NetBird endpoint | Persistent data |
| --- | --- | --- |
| SSH | TCP 22 | NVMe |
| Samba | `\\argon\files`, `\\argon\media` | RAID |
| Immich | `http://argon:2283` | Photos on RAID; database and state on NVMe |
| Jellyfin | `http://argon:8096` | Media on RAID; metadata and cache on NVMe |
| qBittorrent | `http://argon:8080` | Downloads on RAID; configuration on NVMe |
| CUPS | `http://argon:631` | Configuration and spool on NVMe |
| NetBird | UDP 51820 | State on NVMe |

Service storage uses separate Unix groups so each daemon only receives the
access it needs. Immich and Jellyfin retain the upstream systemd hardening, with
`PrivateUsers` disabled so their host storage groups and Arc render device stay
visible. qBittorrent keeps `PrivateUsers` and runs with `downloads` as its
primary group.

The listed application ports are open on the server's LAN and NetBird
interfaces. Keep router ingress and port forwarding closed, including IPv6,
unless public access is explicitly intended.

## Installation

### 1. Prepare the installer and configuration

Boot a NixOS 26.05 ISO in UEFI mode, then become root and confirm networking:

```sh
sudo -i
ping -c 3 nixos.org
```

Clone this repository and pin its flake inputs:

```sh
git clone <YOUR_REPOSITORY_URL> /tmp/argon
cd /tmp/argon
nix --extra-experimental-features "nix-command flakes" flake lock
git add flake.lock
```

Staging the generated lock file makes it visible to Git-backed flake commands.
If `/tmp/argon` came from an archive rather than Git, omit `git add`.

Evaluate the complete host configuration before changing any disks:

```sh
nix --extra-experimental-features "nix-command flakes" eval \
  .#nixosConfigurations.argon.config.system.build.toplevel.drvPath
```

### 2. Verify the three disk IDs

Confirm that all configured IDs exist and match the expected model, size, and
serial number:

```sh
ls -l /dev/disk/by-id/nvme-WD_BLACK_SN850_Heatsink_1TB_21490K485613
ls -l /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ
ls -l /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,MOUNTPOINTS
```

The HDD paths must identify the complete disks, not `-part1` links.

### 3. Format and mount the NVMe

`hosts/argon/disko.nix` already targets:

```text
/dev/disk/by-id/nvme-WD_BLACK_SN850_Heatsink_1TB_21490K485613
```

The next command erases that NVMe. Run it only after checking the ID above:

```sh
cd /tmp/argon
nix --extra-experimental-features "nix-command flakes" run \
  .#disko -- \
  --mode destroy,format,mount \
  ./hosts/argon/disko.nix
findmnt -R /mnt
```

### 4. Mount the data RAID

Choose the new-array or existing-array path below.

#### New array: both HDDs are blank

Inspect both disks without changing them:

```sh
wipefs -n /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ
wipefs -n /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW
mdadm --examine /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ || true
mdadm --examine /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW || true
```

Continue only if both complete disks are disposable and have no partitions,
filesystem signatures, or mdadm metadata. The helper checks these conditions,
asks for a typed confirmation, creates `/dev/md/argon-data`, and formats it as
ext4 with the `ARGON_DATA` label:

```sh
cd /tmp/argon
./scripts/create-data-raid.sh \
  /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ \
  /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW \
  --i-understand-this-erases-both-disks
```

Mount the new filesystem. Initial RAID synchronization may continue in the
background during installation.

```sh
mkdir -p /mnt/srv/storage
mount /dev/disk/by-label/ARGON_DATA /mnt/srv/storage
findmnt /mnt/srv/storage
cat /proc/mdstat
```

#### Existing array: preserve its data

Do not run the RAID creation helper or any `mkfs`, `wipefs`, or `mdadm --create`
command. Check whether the installer assembled the array automatically:

```sh
cat /proc/mdstat
```

If it is absent, assemble and inspect it:

```sh
mdadm --assemble --scan
cat /proc/mdstat
mdadm --detail --scan
lsblk -f
```

If scanning does not find it, supply the two existing members explicitly:

```sh
mdadm --assemble /dev/md/argon-data \
  /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ \
  /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW
```

Stop and inspect `mdadm --examine` output if assembly fails. Do not try
`--create` or `--force` as a recovery shortcut.

Verify the filesystem label, then mount it:

```sh
blkid | grep ARGON_DATA
mkdir -p /mnt/srv/storage
mount /dev/disk/by-label/ARGON_DATA /mnt/srv/storage
findmnt /mnt/srv/storage
ls -la /mnt/srv/storage
```

If the existing filesystem has another label, either update
`hosts/argon/storage.nix` to use its `/dev/disk/by-uuid/...` path or, after
confirming it is the right ext4 filesystem, assign the expected label with
`e2label`. Do not format it.

### 5. Install NixOS

Copy the evaluated configuration and lock file to the target system:

```sh
mkdir -p /mnt/etc/nixos
rsync -a --delete /tmp/argon/ /mnt/etc/nixos/
cd /mnt/etc/nixos
test -f flake.lock
nixos-install --flake .#argon
```

The initial `argon` account is locked because no default password is stored in
Git. Set its password before rebooting:

```sh
nixos-enter --root /mnt -c 'passwd argon'
reboot
```

## First boot

Start with a quick system and storage check:

```sh
systemctl --failed
findmnt /srv/storage
cat /proc/mdstat
```

### NetBird and SSH

Join the NetBird network and verify its interface:

```sh
sudo netbird up
netbird status
ip address show wt0
```

Password SSH login is enabled for setup. Add a public key to
`hosts/argon/local.nix`, rebuild, and confirm both LAN and NetBird key-based
sessions work. Then uncomment the `lib.mkForce false` password-authentication
setting and rebuild again.

```sh
ssh argon@argon
ssh argon@ARGON_NETBIRD_IP
```

### Samba

Create Samba's separate password entry for `argon`:

```sh
sudo smbpasswd -a argon
```

The shares are `\\argon\files` and `\\argon\media`; the hostname can be
replaced with a LAN or NetBird IP.

### Arc A380, Immich, and Jellyfin

Verify that the Arc A380 (`8086:56a5`) owns the stable render link:

```sh
lspci -nn | grep -Ei 'VGA|Display'
ls -l /dev/dri /dev/dri/by-path
readlink -f /dev/dri/argon-arc
vainfo --display drm --device /dev/dri/argon-arc
```

If the link is missing, compare the PCI ID from `lspci` with the udev rule in
`hosts/argon/hardware.nix`.

Open Immich at `http://argon:2283`. Photos are stored under
`/srv/storage/photos/immich`. Select Intel hardware acceleration in Immich's
administration settings and test a video transcode.

Open Jellyfin at `http://argon:8096` and add libraries from
`/srv/storage/media`. Quick Sync, hardware encoding, and the selected codecs are
seeded from the NixOS configuration. Confirm GPU use during a transcode with:

```sh
sudo intel_gpu_top
```

Immich's PostgreSQL database is dumped to
`/srv/storage/backups/postgresql` every day at 03:15. The current and previous
dumps are retained.

```sh
sudo systemctl status postgresqlBackup-immich.timer
sudo ls -lh /srv/storage/backups/postgresql
```

### qBittorrent

Open `http://argon:8080`. On first launch, find the temporary Web UI password in
the service log, sign in, and replace it:

```sh
sudo journalctl -u qbittorrent -b | grep -i password
```

Completed downloads go to `/srv/storage/downloads/complete`; incomplete ones go
to `/srv/storage/downloads/incomplete`. Peer traffic uses TCP and UDP port
52000.

### CUPS

Open `http://argon:631`, authenticate as `argon`, add the printer, and mark it
shared. Clients can use:

```text
ipp://argon:631/printers/PRINTER_NAME
```

Use the NetBird IP or DNS name instead of `argon` for remote printing.

## Python automations

Each automation lives in `/home/argon/automation/<name>/main.py`. A hardened
systemd template runs it with `uv`, so dependencies can come from a
`pyproject.toml` or PEP 723 metadata instead of the global Python environment.

```sh
mkdir -p ~/automation/hello
cp /etc/nixos/examples/automation/hello/main.py ~/automation/hello/main.py
sudo systemctl start argon-automation@hello.service
sudo journalctl -u argon-automation@hello.service
```

To schedule an automation, add a timer using the example in
`hosts/argon/local.nix`, then rebuild. That file is also the place for SSH public
keys and host-specific overrides. Keep passwords, tokens, and private keys out
of Nix expressions because Nix store contents are readable by local users.

## Power policy

The configuration enables Intel P-state with a power-focused energy preference,
deep CPU idle states, supported PCIe ASPM, Powertop tuning, SATA link power
management, audio power saving, periodic SSD trim, and zram. It does not enable
`pcie_aspm=force` or HDD spindown by default because both need hardware-specific
testing.

After RAID synchronization and media indexing settle, measure the idle system:

```sh
sudo powertop
sudo turbostat --interval 5
cat /sys/module/pcie_aspm/parameters/policy
lspci -vv | grep -E 'LnkCap:|LnkCtl:|ASPM'
```

`hosts/argon/local.nix` contains an optional 30-minute HDD standby policy using
the configured stable HDD IDs. Check actual access patterns and SMART start/stop
counts before enabling it. If Powertop tuning causes device instability, disable
`powerManagement.powertop.enable` first and retest.

## Maintenance

### Rebuild and update

```sh
cd /etc/nixos
sudo nixos-rebuild switch --flake .#argon
```

Update deliberately and review the NixOS release notes first:

```sh
cd /etc/nixos
sudo nix flake update
sudo nixos-rebuild build --flake .#argon
sudo nixos-rebuild switch --flake .#argon
```

Automatic upgrades are configured but disabled. Nix garbage collection runs
weekly, SSD trim runs periodically, and the RAID consistency check and Btrfs
scrub run monthly.

### Storage health

```sh
cat /proc/mdstat
sudo mdadm --detail "$(findmnt -no SOURCE /srv/storage)"
sudo smartctl -a /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ
sudo smartctl -a /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW
sudo systemctl status smartd
sudo journalctl -t mdadm
```

mdadm events are logged under the `mdadm` journal tag. External alert delivery
is not configured.

When replacing a failed RAID member, take the array and member paths from
`mdadm --detail`, verify the replacement disk's stable ID and physical serial,
then fail/remove the old member and add the blank replacement. Monitor rebuild
progress in `/proc/mdstat`.

### Back up NVMe state before reinstalling

The RAID survives the reinstall procedure; `/var` does not. Before erasing a
working NVMe, create a current database dump and stop the services whose local
state will be copied:

```sh
sudo systemctl start postgresqlBackup-immich.service
sudo systemctl status postgresqlBackup-immich.service
sudo systemctl stop \
  immich-server.service \
  immich-machine-learning.service \
  jellyfin.service \
  qbittorrent.service \
  cups.service \
  samba-smbd.service
```

From a local console or LAN session, NetBird can also be stopped for a
consistent copy. Do not stop it from a NetBird-only session.

```sh
sudo systemctl stop netbird.service
```

Copy the relevant state to a dated directory on the RAID:

```sh
backup="/srv/storage/backups/pre-reinstall-$(date +%F)"
sudo install -d -m 0700 "$backup"
sudo rsync -aHAXR --numeric-ids --ignore-missing-args \
  /./etc/nixos \
  /./home/argon/automation \
  /./var/lib/immich \
  /./var/lib/jellyfin \
  /./var/cache/jellyfin \
  /./var/lib/qBittorrent \
  /./var/lib/cups \
  /./var/cache/cups \
  /./var/spool/cups \
  /./var/lib/samba \
  /./var/lib/netbird \
  "$backup/"
```

Restart the stopped services if the old installation will remain online.
Restore Immich from its logical PostgreSQL dump; restore other state directories
only while their services are stopped.

`restic` and `rclone` are installed for a future off-site backup, but no remote,
credentials, schedule, or retention policy is configured yet. At minimum, back
up irreplaceable RAID data, PostgreSQL dumps, automation scripts, and selected
NVMe service configuration, then test restores.

## Repository map

| Path | Role |
| --- | --- |
| `flake.nix` | Inputs and `argon` host definition |
| `hosts/argon/disko.nix` | Destructive NVMe layout; never contains the HDDs |
| `hosts/argon/storage.nix` | Non-destructive RAID mount, permissions, and health jobs |
| `hosts/argon/services.nix` | Applications and automation runner |
| `hosts/argon/hardware.nix` | Intel CPU and Arc A380 support |
| `hosts/argon/local.nix` | Host-specific examples and overrides |
| `modules/power.nix` | Low-power policy |
| `scripts/create-data-raid.sh` | Guarded, one-time RAID1 creation |

Further reading: [NixOS manual](https://nixos.org/manual/nixos/stable/),
[disko](https://github.com/nix-community/disko),
[NetBird](https://docs.netbird.io/), [Immich](https://immich.app/docs/), and
[Jellyfin Intel acceleration](https://jellyfin.org/docs/general/post-install/transcoding/hardware-acceleration/intel/).
