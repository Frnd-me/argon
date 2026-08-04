{
  description = "NixOS configuration for the argon home server";

  inputs = {
    # Keep the OS and Home Manager on the same NixOS release line.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      # Reuse the host package set instead of evaluating a second nixpkgs.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      nixpkgs,
      home-manager,
      disko,
      ...
    }:
    let
      system = "x86_64-linux";
      hostname = "argon";
      username = "argon";
    in
    {
      # Expose the pinned disko CLI used by README.md.
      packages.${system}.disko = disko.packages.${system}.disko;

      nixosConfigurations.argon = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs hostname username; };

        modules = [
          # Disk layout and Home Manager are integrated into the host module
          # graph so one evaluation validates the complete machine.
          disko.nixosModules.disko
          home-manager.nixosModules.home-manager
          ./hosts/argon/configuration.nix

          {
            home-manager = {
              extraSpecialArgs = { inherit inputs hostname username; };
              useGlobalPkgs = true;
              useUserPackages = true;
              users.${username} = import ./users/${username}/home.nix;
            };

            # Keep this at the release used for the first installation.
            system.stateVersion = "26.05";
          }
        ];
      };
    };
}
