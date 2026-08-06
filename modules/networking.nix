{ hostname, ... }:
{
  networking = {
    hostName = hostname;
    # systemd-networkd owns the single wired LAN; NetworkManager is unnecessary
    # on this headless host.
    useDHCP = false;
    useNetworkd = true;
    networkmanager.enable = false;

    nftables.enable = true;
    firewall = {
      enable = true;

      # These ports are reachable from both the LAN and NetBird. They are not
      # exposed through an IPv4 router unless port forwarding is configured, but
      # the router's inbound IPv6 policy must also be checked.
      allowedTCPPorts = [
        22 # SSH
        445 # SMB
        631 # CUPS / IPP
        2283 # Immich
        4533 # Navidrome
        6060 # Grimmory
        8096 # Jellyfin
        8080 # qBittorrent Web UI
        28981 # Paperless-ngx
        52000 # BitTorrent peer TCP
      ];
      allowedUDPPorts = [
        5353 # mDNS discovery
        52000 # BitTorrent peer UDP/uTP
      ];
    };
  };

  systemd.network = {
    enable = true;
    wait-online.anyInterface = true;
    # Match predictable wired interface names while leaving NetBird's wt0 to
    # the NetBird module.
    networks."10-lan" = {
      matchConfig.Name = "en*";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = true;
      };
      linkConfig.RequiredForOnline = "routable";
    };
  };

  # Password login is a bootstrap path. local.nix contains the key-only switch.
  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = false;
    };
  };

  # Advertise the hostname and shared services to LAN clients without a full
  # desktop discovery stack.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };
}
