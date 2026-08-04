{ ... }:
{
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      warn-dirty = false;
    };

    # Bound store growth; the weekly job is infrequent enough not to create
    # constant background disk activity.
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  time.timeZone = "Europe/Vienna";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  security.sudo.wheelNeedsPassword = true;
  services.fstrim.enable = true;
  # Bound log retention so an unattended service cannot fill the NVMe.
  services.journald.extraConfig = ''
    SystemMaxUse=1G
    MaxRetentionSec=1month
    Compress=yes
  '';

  environment.variables.EDITOR = "nano";
  programs.nano.enable = true;

  # Keep upgrade policy documented but manual: surprise builds or reboots are
  # undesirable on a storage server and can wake otherwise idle disks.
  system.autoUpgrade = {
    enable = false;
    flake = "/etc/nixos#argon";
    flags = [ "--update-input" "nixpkgs" ];
    dates = "Sun 04:30";
    randomizedDelaySec = "45min";
    allowReboot = false;
  };

}
