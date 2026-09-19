{ lib, pkgs, ... }:
let
  grimmoryNetwork = "argon-grimmory";
  grimmoryAppSecret = "/var/lib/argon-secrets/grimmory-app.env";
  grimmoryDbSecret = "/var/lib/argon-secrets/grimmory-db.env";

  # Make a transactionally consistent database dump while MariaDB is online.
  # The password is expanded inside the container and never enters the Nix
  # store or the host command line.
  grimmoryBackup = pkgs.writeShellScript "grimmory-backup" ''
    set -euo pipefail
    umask 0077

    destination=/srv/storage/backups/grimmory
    timestamp="$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S)"
    temporary="$destination/.grimmory-$timestamp.sql.zst.partial"
    output="$destination/grimmory-$timestamp.sql.zst"

    trap '${pkgs.coreutils}/bin/rm -f "$temporary"' EXIT
    ${pkgs.podman}/bin/podman exec grimmory-db sh -c \
      'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mariadb-dump --single-transaction --quick -u root grimmory' \
      | ${pkgs.zstd}/bin/zstd -T1 -6 -o "$temporary"
    ${pkgs.coreutils}/bin/mv "$temporary" "$output"
    trap - EXIT

    ${pkgs.findutils}/bin/find "$destination" -type f \
      -name 'grimmory-*.sql.zst' -mtime +7 -delete
  '';
in
{
  # Navidrome's index and cache stay on the NVMe. Only the music and its small
  # native database backups touch RAID. File watching replaces periodic scans.
  services.navidrome = {
    enable = true;
    openFirewall = false;
    settings = {
      Address = "0.0.0.0";
      Port = 4533;
      MusicFolder = "/srv/storage/media/music";
      DataFolder = "/var/lib/navidrome";
      EnableInsightsCollector = false;
      EnableArtworkPrecache = false;
      Scanner = {
        Schedule = "0";
        WatcherWait = "30s";
      };
      Backup = {
        Path = "/srv/storage/backups/navidrome";
        Schedule = "25 3 * * *";
        Count = 7;
      };
    };
  };

  # Grimmory is not packaged as a native NixOS service. Pin both upstream
  # images and keep their mutable application/database state on the NVMe.
  virtualisation.oci-containers = {
    backend = "podman";
    containers = {
      grimmory-db = {
        image = "lscr.io/linuxserver/mariadb:11.4.5";
        pull = "missing";
        environment = {
          PUID = "1100";
          PGID = "1100";
          TZ = "Europe/Vienna";
          MYSQL_DATABASE = "grimmory";
          MYSQL_USER = "grimmory";
        };
        environmentFiles = [ grimmoryDbSecret ];
        volumes = [ "/var/lib/grimmory/mariadb:/config" ];
        networks = [ grimmoryNetwork ];
        podman.sdnotify = "healthy";
        extraOptions = [
          "--health-cmd=mariadb-admin ping -h localhost"
          "--health-interval=5s"
          "--health-timeout=5s"
          "--health-retries=20"
          "--health-start-period=30s"
        ];
      };

      grimmory = {
        image = "docker.io/grimmory/grimmory:v3.2.4";
        pull = "missing";
        dependsOn = [ "grimmory-db" ];
        environment = {
          USER_ID = "1100";
          GROUP_ID = "1100";
          TZ = "Europe/Vienna";
          BOOKLORE_PORT = "6060";
          DATABASE_URL = "jdbc:mariadb://grimmory-db:3306/grimmory";
          DATABASE_USERNAME = "grimmory";
        };
        environmentFiles = [ grimmoryAppSecret ];
        volumes = [
          "/var/lib/grimmory/data:/app/data"
          "/srv/storage/library/books:/books"
          "/srv/storage/library/bookdrop:/bookdrop"
        ];
        networks = [ grimmoryNetwork ];

        # OCI port publishing bypasses the NixOS firewall. Bind to loopback and
        # expose it through the socket-activated proxy below instead.
        ports = [ "127.0.0.1:16060:6060" ];
      };
    };
  };

  # Stable IDs make bind-mounted file ownership agree inside and outside the
  # containers. This account has no login shell or home directory.
  # Navidrome needs the host media group. Its service override below disables
  # only PrivateUsers while retaining the chroot and read-only music bind.
  users = {
    groups.grimmory.gid = 1100;
    users = {
      argon.extraGroups = [ "grimmory" ];
      grimmory = {
        isSystemUser = true;
        uid = 1100;
        group = "grimmory";
      };
      navidrome.extraGroups = [
        "media"
        "backups"
      ];
    };
  };

  systemd = {
    tmpfiles.rules = [
      "d /var/lib/argon-secrets 0700 root root -"
      "d /var/lib/grimmory 0750 grimmory grimmory -"
      "d /var/lib/grimmory/data 0750 grimmory grimmory -"
      "d /var/lib/grimmory/mariadb 0750 grimmory grimmory -"
      "d /srv/storage/library 2770 argon grimmory -"
      "d /srv/storage/library/books 2770 argon grimmory -"
      "d /srv/storage/library/bookdrop 2770 argon grimmory -"
      "d /srv/storage/backups/navidrome 0700 navidrome navidrome -"
      "d /srv/storage/backups/grimmory 0700 root root -"
    ];

    # Create the private bridge before either container starts. Leaving the
    # network in place across restarts avoids needless network churn.
    services.grimmory-network = {
      description = "Podman network for Grimmory";
      path = [ pkgs.podman ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        podman network exists ${grimmoryNetwork} \
          || podman network create ${grimmoryNetwork}
      '';
    };

    services.podman-grimmory-db = {
      requires = [ "grimmory-network.service" ];
      after = [ "grimmory-network.service" ];
      unitConfig = {
        ConditionPathExists = grimmoryDbSecret;
        RequiresMountsFor = [ "/var/lib/grimmory/mariadb" ];
      };
    };

    services.podman-grimmory = {
      requires = [ "grimmory-network.service" ];
      after = [ "grimmory-network.service" ];
      unitConfig = {
        ConditionPathExists = [
          grimmoryAppSecret
        ];
        RequiresMountsFor = [
          "/var/lib/grimmory/data"
          "/srv/storage"
        ];
      };
    };

    # systemd-socket-proxyd is started only while Grimmory has clients. The
    # public 6060 listener remains governed by the NixOS nftables firewall.
    sockets.grimmory-proxy = {
      description = "Firewall-aware Grimmory listener";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "6060" ];
    };
    services.grimmory-proxy = {
      description = "Proxy connections to the loopback-only Grimmory port";
      requires = [ "podman-grimmory.service" ];
      after = [ "podman-grimmory.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 127.0.0.1:16060";
        DynamicUser = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
      };
    };

    services.grimmory-backup = {
      description = "Back up the Grimmory MariaDB database";
      requires = [ "podman-grimmory-db.service" ];
      after = [ "podman-grimmory-db.service" ];
      unitConfig = {
        ConditionPathExists = [
          grimmoryDbSecret
        ];
        RequiresMountsFor = [ "/srv/storage" ];
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = grimmoryBackup;
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };
    services.navidrome = {
      unitConfig = {
        RequiresMountsFor = [ "/srv/storage" ];
      };
      serviceConfig.PrivateUsers = lib.mkForce false;
    };
    timers.grimmory-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 03:30:00";
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };
  };

}
