{ hostname, ... }:
{
  networking = {
    hostName = hostname;
    # systemd-networkd owns the four onboard ports and their bridge;
    # NetworkManager is unnecessary on this headless host.
    useDHCP = false;
    dhcpcd.enable = false;
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

    # Put all four onboard ports in one layer-2 bridge. Any one can be the
    # uplink to the existing LAN; devices on the others share that LAN as if
    # they were connected to an ordinary Ethernet switch.
    netdevs."10-lan-bridge" = {
      netdevConfig = {
        Kind = "bridge";
        Name = "br0";
        # Keep the former uplink's MAC as the bridge's stable LAN identity.
        MACAddress = "00:03:ee:00:67:51";
      };
      # Protect against an accidental second uplink forming a layer-2 loop.
      bridgeConfig.STP = true;
    };

    networks = {
      "10-lan-ports" = {
        # Deliberately exclude the temporary USB NIC (enp0s20f0u1).
        matchConfig.Name = "enp2s0 enp3s0 enp4s0 enp5s0";
        networkConfig = {
          Bridge = "br0";
          DHCP = "no";
          IPv6AcceptRA = false;
          LinkLocalAddressing = "no";
        };
        # Unplugged switch ports must not delay boot or network-online.target.
        linkConfig.RequiredForOnline = false;
      };

      "20-lan-bridge" = {
        matchConfig.Name = "br0";
        # Layer-3 configuration belongs only to the bridge, never its ports.
        networkConfig = {
          DHCP = "yes";
          IPv6AcceptRA = true;
        };
        linkConfig.RequiredForOnline = "routable";
      };
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
