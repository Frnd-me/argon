{ lib, pkgs, ... }:
{
  # Host-specific settings belong here. This file is tracked so flakes include
  # it reliably. Public keys and hardware IDs are fine; do not put secret values
  # directly in Nix expressions because they become readable in the Nix store.

  # After confirming key-based login, uncomment both settings and rebuild:
  # users.users.argon.openssh.authorizedKeys.keys = [
  #   "ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY"
  # ];
  # services.openssh.settings.PasswordAuthentication = lib.mkForce false;

  # Example: run /home/argon/automation/mein-postkorb/main.py every weekday.
  # systemd.timers."argon-automation@mein-postkorb" = {
  #   wantedBy = [ "timers.target" ];
  #   timerConfig = {
  #     OnCalendar = "Mon..Fri 07:00";
  #     Persistent = true;
  #     RandomizedDelaySec = "5min";
  #   };
  # };

  # Optional HDD standby. Verify both IDs before uncommenting this service.
  # Frequent downloads, media scans, SMART tests, RAID checks, and backups can
  # make spindown counterproductive by repeatedly waking the drives.
  # environment.systemPackages = [ pkgs.hdparm ];
  # systemd.services.argon-hdd-standby-policy = {
  #   description = "Configure HDD standby timeouts";
  #   wantedBy = [ "multi-user.target" ];
  #   after = [ "local-fs.target" ];
  #   serviceConfig.Type = "oneshot";
  #   script = ''
  #     ${pkgs.hdparm}/bin/hdparm -S 241 /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD1ZSNZ
  #     ${pkgs.hdparm}/bin/hdparm -S 241 /dev/disk/by-id/ata-ST2000VX017-3CV102_WWD37CTW
  #   '';
  # };
}
