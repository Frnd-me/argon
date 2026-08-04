{ pkgs, username, ... }:
{
  # Keep user-level tools and shell state declarative without enabling a
  # graphical session or user daemons on this headless server.
  home = {
    inherit username;
    homeDirectory = "/home/${username}";
    stateVersion = "26.05";
    packages = with pkgs; [
      rclone
    ];
  };

  programs = {
    home-manager.enable = true;
    git.enable = true;
    zsh.enable = true;
  };
}
