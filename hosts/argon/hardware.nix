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
    # media-driver provides Intel QSV/VA-API; compute-runtime provides OpenCL
    # used by media workloads such as tone mapping on the Arc A380.
    extraPackages = with pkgs; [
      intel-media-driver
      intel-compute-runtime
    ];
  };

  # This headless wired server has no Bluetooth workload or daemon.
  hardware.bluetooth.enable = false;

  # Stable device name for the Arc A380 (PCI device ID 8086:56a5).
  services.udev.extraRules = ''
    SUBSYSTEM=="drm", KERNEL=="renderD*", ATTRS{vendor}=="0x8086", ATTRS{device}=="0x56a5", SYMLINK+="dri/argon-arc"
  '';
}
