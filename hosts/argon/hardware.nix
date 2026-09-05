{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # Drivers required to reach the NVMe, SATA disks, and USB recovery media in
  # the initrd. Loading availability here does not keep unused USB devices on.
  boot.initrd.availableKernelModules = [
    "ahci"
    "nvme"
    "sd_mod"
    "uas"
    "usb_storage"
    "xhci_pci"
  ];
  boot.kernelModules = [ "kvm-intel" ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  hardware.enableRedistributableFirmware = true;
  hardware.graphics = {
    enable = true;
    # The iHD media driver provides VA-API and Quick Sync support for the
    # i3-9100T's integrated UHD 630.
    extraPackages = with pkgs; [ intel-media-driver ];
  };

  # This headless wired server has no Bluetooth workload or daemon.
  hardware.bluetooth.enable = false;

  # The integrated GPU is always at PCI 0000:00:02.0 on this platform. Give its
  # render node a stable name so service configuration is independent of DRM
  # card enumeration order.
  services.udev.extraRules = ''
    SUBSYSTEM=="drm", KERNEL=="renderD*", KERNELS=="0000:00:02.0", SYMLINK+="dri/argon-igpu"
  '';
}
