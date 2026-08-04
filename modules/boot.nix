{
  # The machine boots in UEFI mode from the NVMe; limiting generations keeps
  # the small EFI system partition tidy.
  boot.loader = {
    systemd-boot = {
      enable = true;
      configurationLimit = 10;
    };
    efi.canTouchEfiVariables = true;
  };

  boot.initrd.systemd.enable = true;
  boot.tmp.cleanOnBoot = true;
  # Compressed RAM swap avoids a permanently active disk swap device and its
  # associated idle I/O.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 25;
  };
}
