{ ... }:
let
  # Created by the recovery runbook before the first boot of a replacement
  # installation. A negated condition keeps mutable applications and backup
  # jobs stopped until their previous state has been restored and verified.
  recoveryCondition = [ "!/var/lib/argon-recovery-mode" ];
in
{
  systemd.services = {
    immich-server.unitConfig.ConditionPathExists = recoveryCondition;
    immich-machine-learning.unitConfig.ConditionPathExists = recoveryCondition;
    jellyfin.unitConfig.ConditionPathExists = recoveryCondition;
    navidrome.unitConfig.ConditionPathExists = recoveryCondition;
    qbittorrent.unitConfig.ConditionPathExists = recoveryCondition;
    samba-smbd.unitConfig.ConditionPathExists = recoveryCondition;

    paperless-consumer.unitConfig.ConditionPathExists = recoveryCondition;
    paperless-scheduler.unitConfig.ConditionPathExists = recoveryCondition;
    paperless-task-queue.unitConfig.ConditionPathExists = recoveryCondition;
    paperless-web.unitConfig.ConditionPathExists = recoveryCondition;

    podman-grimmory.unitConfig.ConditionPathExists = recoveryCondition;
    grimmory-proxy.unitConfig.ConditionPathExists = recoveryCondition;
    grimmory-backup.unitConfig.ConditionPathExists = recoveryCondition;

    "argon-automation@".unitConfig.ConditionPathExists = recoveryCondition;
    "postgresqlBackup-immich".unitConfig.ConditionPathExists = recoveryCondition;
    "postgresqlBackup-paperless".unitConfig.ConditionPathExists = recoveryCondition;

    "restic-backups-argon-system".unitConfig.ConditionPathExists = recoveryCondition;
    "restic-backups-argon-data".unitConfig.ConditionPathExists = recoveryCondition;
    "restic-backups-argon-system-check".unitConfig.ConditionPathExists = recoveryCondition;
    "restic-backups-argon-data-check".unitConfig.ConditionPathExists = recoveryCondition;
  };

  systemd.sockets.grimmory-proxy.unitConfig.ConditionPathExists = recoveryCondition;
}
