{ pkgs, ... }:
let
  # mdadm requires a notification target when monitoring arrays. Log events to
  # the system journal without requiring a local mail server.
  mdadmNotify = pkgs.writeShellScript "argon-mdadm-notify" ''
    ${pkgs.util-linux}/bin/logger -t mdadm -- "$@"
  '';
in
{
  boot = {
    swraid = {
      enable = true;
      mdadmConf = "PROGRAM ${mdadmNotify}";
    };
    supportedFilesystems = [ "btrfs" "ext4" ];
  };

  # The array is created manually once. Subsequent boots only assemble it and
  # mount its filesystem by label. autoFormat is intentionally not enabled.
  fileSystems."/srv/storage" = {
    device = "/dev/disk/by-label/ARGON_DATA";
    fsType = "ext4";
    options = [
      "noatime"
      "lazytime"
      "errors=remount-ro"
      "x-systemd.device-timeout=60s"
    ];
  };

  users.groups = {
    nas = { };
    media = { };
    downloads = { };
    photos = { };
    backups = { };
  };

  # Separate groups keep services from modifying unrelated data. Argon owns
  # the shared trees; daemons receive access only to their own subtree.
  systemd.tmpfiles.rules = [
    "d /srv/storage 0755 root root -"
    "d /srv/storage/files 2770 argon nas -"
    "d /srv/storage/photos 2750 argon photos -"
    # Match the Immich module's privacy-preserving ownership and mode.
    "d /srv/storage/photos/immich 0700 immich immich -"
    "d /srv/storage/media 2750 argon media -"
    "d /srv/storage/media/music 2750 argon media -"
    # Paperless owns the private document directories created by its module.
    "d /srv/storage/documents 0755 root root -"
    "d /srv/storage/downloads 2770 qbittorrent downloads -"
    "d /srv/storage/downloads/complete 2770 qbittorrent downloads -"
    "d /srv/storage/downloads/incomplete 2770 qbittorrent downloads -"
    "d /srv/storage/backups 2770 root backups -"
  ];

  services.smartd = {
    enable = true;
    autodetect = true;

    # Do not wake a disk solely for a periodic SMART poll if it is already in
    # standby. Active drives are still checked normally.
    defaults.autodetected = "-a -n standby,q";
  };

  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];
    limit = "100M";
  };

  # Check the md RAID mirror monthly. SMART monitoring above separately reports
  # failing drives.
  systemd.services.mdraid-check = {
    description = "Start a consistency check on all Linux MD arrays";
    serviceConfig.Type = "oneshot";
    script = ''
      shopt -s nullglob
      for action in /sys/block/md*/md/sync_action; do
        if [[ $(<"$action") == idle ]]; then
          echo check > "$action"
        fi
      done
    '';
  };

  systemd.timers.mdraid-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "monthly";
      Persistent = true;
      RandomizedDelaySec = "6h";
    };
  };

  environment.systemPackages = with pkgs; [
    btrfs-progs
    mdadm
    smartmontools
  ];
}
