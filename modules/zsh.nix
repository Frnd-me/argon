{ pkgs, ... }:
{
  # Lightweight interactive shell conveniences for local and SSH maintenance.
  programs = {
    starship.enable = true;
    zsh = {
      enable = true;
      syntaxHighlighting.enable = true;
      autosuggestions.enable = true;
    };
  };

  users.defaultUserShell = pkgs.zsh;
}
