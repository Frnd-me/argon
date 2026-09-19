{ pkgs, ... }:
let
  secretDirectory = "/var/lib/argon-secrets";
  passwordFile = "${secretDirectory}/restic-password";
  sshPrivateKey = "${secretDirectory}/restic-ssh-key";
  sshKnownHosts = "${secretDirectory}/restic-known-hosts";
  systemRepositoryFile = "${secretDirectory}/restic-system-repository";
  dataRepositoryFile = "${secretDirectory}/restic-data-repository";

  # The repository URLs supply the user, host, and port. Keep authentication
  # arguments here so no backup can silently fall back to a password prompt or
  # accept an unverified host key.
  sftpOptions = [
    "sftp.args='-i ${sshPrivateKey} -o BatchMode=yes -o IdentitiesOnly=yes -o UserKnownHostsFile=${sshKnownHosts} -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ServerAliveInterval=60 -o ServerAliveCountMax=240'"
  ];

  commonBackup = {
    inherit passwordFile;
    extraOptions = sftpOptions;
    initialize = true;
  };

  commonRetention = [
    "--keep-daily 14"
    "--keep-weekly 8"
    "--keep-monthly 12"
    "--keep-yearly 3"
    # Do not strand an old retention group when the path list changes.
    "--group-by host,tags"
  ];

  commonCredentialFiles = [
    passwordFile
    sshPrivateKey
    sshKnownHosts
  ];

  # These services write the state included in argon-system. Stop only units
  # that are currently active, then restore that exact set after Restic has
  # finished (including on failure through the module's postStop hook).
  prepareSystemBackup = ''
    #!${pkgs.runtimeShell}
    set -euo pipefail

    activeFile=/run/restic-backups-argon-system/active-units
    : > "$activeFile"

    for unit in \
      grimmory-proxy.socket \
      grimmory-proxy.service \
      immich-server.service \
      jellyfin.service \
      navidrome.service \
      paperless-consumer.service \
      paperless-scheduler.service \
      paperless-task-queue.service \
      paperless-web.service \
      podman-grimmory.service \
      qbittorrent.service \
      samba-smbd.service
    do
      if ${pkgs.systemd}/bin/systemctl is-active --quiet "$unit"; then
        printf '%s\n' "$unit" >> "$activeFile"
      fi
    done

    mapfile -t activeUnits < "$activeFile"
    if (( ''${#activeUnits[@]} > 0 )); then
      ${pkgs.systemd}/bin/systemctl stop "''${activeUnits[@]}"
    fi
  '';

  cleanupSystemBackup = ''
    #!${pkgs.runtimeShell}
    set -euo pipefail

    activeFile=/run/restic-backups-argon-system/active-units
    if [[ -s "$activeFile" ]]; then
      mapfile -t activeUnits < "$activeFile"
      ${pkgs.systemd}/bin/systemctl start "''${activeUnits[@]}"
    fi
    ${pkgs.coreutils}/bin/rm -f "$activeFile"
  '';

  mkResticService = repositoryFile: extraUnitConfig: {
    unitConfig = {
      ConditionPathExists = commonCredentialFiles ++ [ repositoryFile ];
    }
    // extraUnitConfig;
    serviceConfig = {
      UMask = "0077";
      Nice = 10;
      IOSchedulingClass = "idle";
      IOSchedulingPriority = 7;
      NoNewPrivileges = true;
      ProtectHome = "read-only";
      ProtectSystem = "strict";
    };
  };
in
{
  services.restic.backups = {
    # The operating system and packages are reproducible from the flake. Save
    # only machine identity, local secrets, automations, and useful service
    # state from the NVMe. Live SQL databases are deliberately absent: their
    # consistent dumps are stored on the RAID and covered by argon-data.
    "argon-system" = commonBackup // {
      repositoryFile = systemRepositoryFile;
      paths = [
        "/etc/nixos"
        "/etc/ssh"
        "/home/argon/automation"
        "/var/lib/argon-secrets"
        "/var/lib/grimmory/data"
        "/var/lib/immich"
        "/var/lib/jellyfin"
        "/var/lib/navidrome"
        "/var/lib/netbird"
        "/var/lib/paperless"
        "/var/lib/qBittorrent"
        "/var/lib/samba"
      ];
      exclude = [
        # A repository cannot recover the password needed to decrypt itself.
        # Keep its password and Storage Box recovery access somewhere external.
        "/var/lib/argon-secrets/restic-*"
        "/home/argon/automation/**/.cache"
        "/home/argon/automation/**/__pycache__"
        "/var/lib/jellyfin/log"
        "/var/lib/navidrome/cache"
      ];
      extraBackupArgs = [
        "--exclude-caches"
        "--tag"
        "argon-system"
      ];
      backupPrepareCommand = prepareSystemBackup;
      backupCleanupCommand = cleanupSystemBackup;
      pruneOpts = commonRetention;
      timerConfig = {
        OnCalendar = "*-*-* 04:15:00";
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
    };

    # Back up the durable RAID as a separate repository so a system restore
    # never requires scanning or downloading the much larger data snapshots.
    "argon-data" = commonBackup // {
      repositoryFile = dataRepositoryFile;
      paths = [ "/srv/storage" ];
      exclude = [
        # Completed and partial torrents are replaceable and can otherwise use
        # most of the 5 TB box through long-lived historical snapshots.
        "/srv/storage/downloads"
      ];
      extraBackupArgs = [
        "--exclude-caches"
        "--one-file-system"
        "--tag"
        "argon-data"
      ];
      pruneOpts = commonRetention;
      timerConfig = {
        # PostgreSQL, Navidrome, and Grimmory create local dumps around 03:30.
        OnCalendar = "*-*-* 05:00:00";
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };

    # Metadata is checked monthly. The small system repository is read in full;
    # the data repository uses a random sample to bound network and disk use.
    "argon-system-check" = commonBackup // {
      repositoryFile = systemRepositoryFile;
      initialize = false;
      paths = [ ];
      createWrapper = false;
      runCheck = true;
      checkOpts = [ "--read-data" ];
      timerConfig = {
        OnCalendar = "*-*-01 08:00:00";
        Persistent = true;
        RandomizedDelaySec = "6h";
      };
    };

    "argon-data-check" = commonBackup // {
      repositoryFile = dataRepositoryFile;
      initialize = false;
      paths = [ ];
      createWrapper = false;
      runCheck = true;
      checkOpts = [ "--read-data-subset=5%" ];
      timerConfig = {
        OnCalendar = "*-*-02 08:00:00";
        Persistent = true;
        RandomizedDelaySec = "6h";
      };
    };
  };

  systemd.services = {
    "restic-backups-argon-system" =
      mkResticService systemRepositoryFile { };
    "restic-backups-argon-data" =
      mkResticService dataRepositoryFile {
        RequiresMountsFor = [ "/srv/storage" ];
      };
    "restic-backups-argon-system-check" =
      mkResticService systemRepositoryFile { };
    "restic-backups-argon-data-check" =
      mkResticService dataRepositoryFile { };
  };
}
