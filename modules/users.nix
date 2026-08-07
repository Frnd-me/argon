{ username, ... }:
{
  users = {
    # The installer sets the initial password interactively. Keeping users
    # mutable also permits normal password rotation without storing a hash here.
    mutableUsers = true;
    users.${username} = {
      isNormalUser = true;
      description = "Argon";
      group = "users";
      home = "/home/${username}";
      createHome = true;
      homeMode = "0700";
      extraGroups = [ "wheel" ];
      hashedPassword = "!";
    };
  };

  # Reassert the writable shell-cache ownership on initial installation and
  # every rebuild before Home Manager and Starship run as the normal user.
  systemd.tmpfiles.rules = [
    "d /home/${username} 0700 ${username} users -"
    "d /home/${username}/.cache 0700 ${username} users -"
    "d /home/${username}/.cache/starship 0700 ${username} users -"
  ];

  systemd.services."home-manager-${username}" = {
    requires = [ "systemd-tmpfiles-setup.service" ];
    after = [ "systemd-tmpfiles-setup.service" ];
  };
}
