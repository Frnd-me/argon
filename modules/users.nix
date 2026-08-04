{ username, ... }:
{
  users = {
    # The installer sets the initial password interactively. Keeping users
    # mutable also permits normal password rotation without storing a hash here.
    mutableUsers = true;
    users.${username} = {
      isNormalUser = true;
      description = "Argon";
      extraGroups = [ "wheel" ];
      hashedPassword = "!";
    };
  };
}
