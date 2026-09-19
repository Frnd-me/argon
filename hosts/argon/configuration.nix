{
  imports = [
    # Machine-specific layout, hardware, storage, and services.
    ./disko.nix
    ./hardware.nix
    ./storage.nix
    ./backup.nix
    ./recovery.nix
    ./services.nix
    ./documents.nix
    ./library.nix
    ./printing.nix
    ./local.nix

    # Reusable system policy shared independently of the physical host.
    ../../modules/boot.nix
    ../../modules/networking.nix
    ../../modules/packages.nix
    ../../modules/power.nix
    ../../modules/system.nix
    ../../modules/users.nix
    ../../modules/zsh.nix
  ];
}
