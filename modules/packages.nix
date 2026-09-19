{ pkgs, ... }:
{
  # Administration and diagnostics only; server applications are declared as
  # services so their users, permissions, and lifecycle stay reproducible.
  environment.systemPackages = with pkgs; [
    curl
    ethtool
    git
    htop
    intel-gpu-tools
    jq
    libva-utils
    lm_sensors
    lsof
    nvme-cli
    pciutils
    powertop
    python3
    restic
    rclone
    ripgrep
    rsync
    smartmontools
    tmux
    tree
    uv
    wget
    zstd

    # turbostat is built from the selected kernel package set.
    linuxPackages.turbostat
  ];
}
