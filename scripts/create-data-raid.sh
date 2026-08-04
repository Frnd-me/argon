#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  sudo ./scripts/create-data-raid.sh \
    /dev/disk/by-id/<first-hdd> \
    /dev/disk/by-id/<second-hdd> \
    --i-understand-this-erases-both-disks

This command is only for two blank drives. It refuses to continue when it finds
mounts, partitions, filesystem signatures, or existing mdadm metadata.
USAGE
}

[[ $# -eq 3 ]] || { usage >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "Run this script as root." >&2; exit 1; }
[[ "$3" == "--i-understand-this-erases-both-disks" ]] || { usage >&2; exit 2; }

for command in blkid cat grep lsblk mdadm mkfs.ext4 readlink udevadm wc wipefs; do
  command -v "$command" >/dev/null || {
    echo "Required command not found: $command" >&2
    exit 1
  }
done

[[ ! -e /dev/md/argon-data ]] || {
  echo "Refusing because /dev/md/argon-data already exists." >&2
  exit 1
}

disk1=$(readlink -f "$1")
disk2=$(readlink -f "$2")

for original in "$1" "$2"; do
  [[ "$original" == /dev/disk/by-id/* ]] || {
    echo "Refusing non-stable device path: $original" >&2
    exit 1
  }
done

[[ -b "$disk1" && -b "$disk2" ]] || { echo "Both arguments must be block devices." >&2; exit 1; }
[[ "$disk1" != "$disk2" ]] || { echo "The two devices resolve to the same disk." >&2; exit 1; }

for disk in "$disk1" "$disk2"; do
  if [[ $(lsblk -dnro TYPE "$disk") != disk ]]; then
    echo "Refusing non-disk block device: $disk" >&2
    exit 1
  fi

  if lsblk -nrpo MOUNTPOINT "$disk" | grep -qE '.+'; then
    echo "Refusing mounted device: $disk" >&2
    lsblk "$disk" >&2
    exit 1
  fi

  if [[ $(lsblk -nrpo TYPE "$disk" | wc -l) -ne 1 ]]; then
    echo "Refusing device with partitions or child devices: $disk" >&2
    lsblk "$disk" >&2
    exit 1
  fi

  if wipefs -n "$disk" | grep -q .; then
    echo "Refusing device with an existing signature: $disk" >&2
    wipefs -n "$disk" >&2
    exit 1
  fi

  if mdadm --examine "$disk" >/dev/null 2>&1; then
    echo "Refusing device with existing mdadm metadata: $disk" >&2
    exit 1
  fi
done

echo "About to create a RAID1 array and ext4 filesystem on:"
echo "  $1 -> $disk1"
echo "  $2 -> $disk2"
read -r -p 'Type ERASE-BOTH-DISKS to continue: ' confirmation
[[ "$confirmation" == "ERASE-BOTH-DISKS" ]] || { echo "Cancelled."; exit 1; }

mdadm --create /dev/md/argon-data \
  --metadata=1.2 \
  --homehost=argon \
  --name=argon-data \
  --level=1 \
  --raid-devices=2 \
  --bitmap=internal \
  "$disk1" "$disk2"

udevadm settle
mkfs.ext4 -F -m 0 -L ARGON_DATA /dev/md/argon-data
udevadm settle

echo
mdadm --detail /dev/md/argon-data
blkid /dev/md/argon-data
cat /proc/mdstat

echo
printf '%s\n' \
  'RAID created. Initial synchronization continues in the background.' \
  'Mount it with: mount /dev/disk/by-label/ARGON_DATA /mnt/srv/storage'
