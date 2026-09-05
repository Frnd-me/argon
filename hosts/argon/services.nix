{ lib, pkgs, ... }:
let
  # Use the stable udev link for the i3-9100T's integrated UHD 630 rather than
  # relying on a renderD number that can change when hardware is added.
  mediaGpu = "/dev/dri/argon-igpu";

  qbitInitialConfig = pkgs.writeText "argon-qbittorrent-initial.conf" ''
    [BitTorrent]
    Session\DefaultSavePath=/srv/storage/downloads/complete
    Session\TempPath=/srv/storage/downloads/incomplete
    Session\TempPathEnabled=true

    [LegalNotice]
    Accepted=true

    [Preferences]
    WebUI\Address=*
  '';

  # The NixOS qBittorrent module rewrites serverConfig on every service start.
  # Seed a config only once so Web UI credentials and later settings persist.
  qbitInitialize = pkgs.writeShellScript "argon-qbittorrent-initialize" ''
    set -euo pipefail
    config=/var/lib/qBittorrent/qBittorrent/config/qBittorrent.conf
    if [[ ! -e "$config" ]]; then
      ${pkgs.coreutils}/bin/install -m 0600 ${qbitInitialConfig} "$config"
    fi
  '';

  automationRunner = pkgs.writeShellScript "argon-automation-runner" ''
    set -euo pipefail

    name="$1"
    directory="/home/argon/automation/$name"

    if [[ ! "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      echo "Invalid automation name: $name" >&2
      exit 2
    fi

    if [[ ! -f "$directory/main.py" ]]; then
      echo "Expected $directory/main.py" >&2
      exit 1
    fi

    cd "$directory"
    exec ${pkgs.uv}/bin/uv run main.py
  '';
in
{
  # One hardened NetBird instance provides remote access without exposing the
  # application services through router port forwards.
  services.netbird.clients.default = {
    name = "netbird";
    interface = "wt0";
    port = 51820;
    hardened = true;
    openFirewall = true;
    openInternalFirewall = true;
  };

  # Samba exposes only the two managed RAID trees and authenticates argon.
  services.samba = {
    enable = true;
    openFirewall = false;
    nmbd.enable = false;
    winbindd.enable = false;
    settings = {
      global = {
        "server role" = "standalone server";
        "security" = "user";
        "map to guest" = "Never";
        "server min protocol" = "SMB3";
        "load printers" = "no";
        "printing" = "bsd";
        "printcap name" = "/dev/null";
      };

      files = {
        path = "/srv/storage/files";
        browseable = "yes";
        "read only" = "no";
        "valid users" = "argon";
        "force group" = "nas";
        "create mask" = "0660";
        "directory mask" = "0770";
      };

      media = {
        path = "/srv/storage/media";
        browseable = "yes";
        "read only" = "no";
        "valid users" = "argon";
        "force group" = "media";
        "create mask" = "0640";
        "directory mask" = "0750";
      };

      # Grimmory gets a separate share so its writable library does not grant
      # the container access to Jellyfin and Navidrome media.
      library = {
        path = "/srv/storage/library";
        browseable = "yes";
        "read only" = "no";
        "valid users" = "argon";
        "force group" = "grimmory";
        "create mask" = "0660";
        "directory mask" = "0770";
      };
    };
  };

  # Large media lives on RAID; application and database state remain on NVMe.
  services.immich = {
    enable = true;
    host = "0.0.0.0";
    port = 2283;
    openFirewall = false;
    mediaLocation = "/srv/storage/photos/immich";
    accelerationDevices = [ mediaGpu ];
    machine-learning.enable = true;
  };

  # Seed a known-good QSV configuration while still allowing later Web UI
  # changes because forceEncodingConfig remains at its default false value.
  services.jellyfin = {
    enable = true;
    openFirewall = false;
    hardwareAcceleration = {
      enable = true;
      type = "qsv";
      device = mediaGpu;
    };
    transcoding = {
      enableHardwareEncoding = true;
      throttleTranscoding = true;
      hardwareDecodingCodecs = {
        h264 = true;
        hevc = true;
        hevc10bit = true;
        vp9 = true;
      };
      # UHD 630 supports HEVC encoding, but has no AV1 hardware codec.
      hardwareEncodingCodecs.hevc = true;
    };
  };

  # Fixed ports keep the firewall and application configuration aligned.
  services.qbittorrent = {
    enable = true;
    group = "downloads";
    openFirewall = false;
    webuiPort = 8080;
    torrentingPort = 52000;
    extraArgs = [ "--confirm-legal-notice" ];
  };

  # Keep restorable database dumps on storage that survives an NVMe reinstall.
  # The upstream module rotates the previous dump automatically.
  services.postgresqlBackup = {
    enable = true;
    databases = [
      "immich"
      "paperless"
    ];
    location = "/srv/storage/backups/postgresql";
    compression = "zstd";
    compressionLevel = 6;
    startAt = "*-*-* 03:15:00";
  };

  # Supplementary groups grant each service only its device and storage paths.
  users.users = {
    argon.extraGroups = [ "nas" "media" "downloads" "photos" "netbird" ];
    immich.extraGroups = [ "photos" "render" "video" ];
    jellyfin.extraGroups = [ "media" "render" "video" ];
    postgres.extraGroups = [ "backups" ];
  };

  # Storage-backed units explicitly depend on /srv/storage so a missing or
  # slow RAID cannot redirect writes into the NVMe mountpoint directory.
  systemd.services = {
    immich-server = {
      unitConfig.RequiresMountsFor = [ "/srv/storage" ];
      # The upstream module enables PrivateUsers. Disable only this sandboxing
      # feature so the host render/video/photos groups remain usable.
      serviceConfig.PrivateUsers = lib.mkForce false;
    };
    jellyfin = {
      unitConfig.RequiresMountsFor = [ "/srv/storage" ];
      # Jellyfin likewise needs the host media/render/video group mappings.
      serviceConfig.PrivateUsers = lib.mkForce false;
    };
    qbittorrent = {
      unitConfig.RequiresMountsFor = [ "/srv/storage" ];
      serviceConfig = {
        ExecStartPre = qbitInitialize;
        UMask = "0002";
      };
    };
    samba-smbd.unitConfig.RequiresMountsFor = [ "/srv/storage" ];
    "postgresqlBackup-immich".unitConfig.RequiresMountsFor = [ "/srv/storage" ];
    "postgresqlBackup-paperless".unitConfig.RequiresMountsFor = [ "/srv/storage" ];

    # Each automation gets a read-only host view plus explicit writable paths.
    "argon-automation@" = {
      description = "Argon Python automation %i";
      unitConfig.RequiresMountsFor = [ "/srv/storage" ];
      path = with pkgs; [
        coreutils
        cups
        curl
        gnugrep
        jq
        util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "argon";
        Group = "users";
        WorkingDirectory = "/home/argon/automation/%i";
        ExecStart = "${automationRunner} %i";
        Environment = [
          "HOME=/home/argon"
          "XDG_CACHE_HOME=/home/argon/automation/%i/.cache"
          "XDG_CONFIG_HOME=/home/argon/automation/%i/.config"
          "XDG_DATA_HOME=/home/argon/automation/%i/.local/share"
        ];
        UMask = "0077";
        Nice = 10;
        IOSchedulingClass = "idle";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadWritePaths = [
          "/home/argon/automation"
          "/home/argon/.cache/uv"
          "/home/argon/.local/share/uv"
          "/srv/storage"
          "-/run/cups"
        ];
      };
    };
  };

  systemd.tmpfiles.rules = [
    "d /home/argon/automation 0750 argon users -"
    "d /home/argon/.cache/uv 0750 argon users -"
    "d /home/argon/.local/share/uv 0750 argon users -"
  ];
}
