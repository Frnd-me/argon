{
  # IMPORTANT: disko only manages the NVMe OS disk. The HDD RAID is deliberately
  # not declared here, so a reinstall cannot reformat it accidentally.
  # Verify this stable device ID against the physical NVMe before install.
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/disk/by-id/nvme-WD_BLACK_SN850_Heatsink_1TB_21490K485613";

    content = {
      type = "gpt";
      partitions = {
        esp = {
          name = "ESP";
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };

        system = {
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = [ "-f" "-L" "ARGON_SYSTEM" ];
            subvolumes = {
              "@root" = {
                mountpoint = "/";
                mountOptions = [
                  "compress=zstd:3"
                  "noatime"
                  "ssd"
                  "discard=async"
                ];
              };

              "@nix" = {
                mountpoint = "/nix";
                mountOptions = [
                  "compress=zstd:3"
                  "noatime"
                  "ssd"
                  "discard=async"
                ];
              };

              "@var" = {
                mountpoint = "/var";
                mountOptions = [
                  "compress=zstd:3"
                  "noatime"
                  "ssd"
                  "discard=async"
                ];
              };

              "@home" = {
                mountpoint = "/home";
                mountOptions = [
                  "compress=zstd:3"
                  "noatime"
                  "ssd"
                  "discard=async"
                ];
              };
            };
          };
        };
      };
    };
  };
}
