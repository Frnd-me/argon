{ lib, pkgs, ... }:
let
  # The live ET-3950 advertises this eSCL endpoint. Pin it as well as leaving
  # discovery enabled, so scanning still works if mDNS is temporarily absent.
  airscanConfig = pkgs.writeTextDir "etc/sane.d/airscan.conf" ''
    [devices]
    "Epson ET-3950" = https://192.168.1.191/eSCL, eSCL

    [options]
    discovery = enable
    ws-discovery = off
  '';
in
{
  # Socket activation leaves CUPS stopped until a print client needs it.
  services.printing = {
    enable = true;
    browsed.enable = false;
    startWhenNeeded = true;
    listenAddresses = [ "*:631" ];
    allowFrom = [ "all" ];
    browsing = true;
    defaultShared = true;
    webInterface = true;
    openFirewall = false;
  };

  # The ET-3950 supports IPP Everywhere, so no model-specific binary driver is
  # required. The fixed address makes the queue reproducible across reboots.
  hardware.printers = {
    ensureDefaultPrinter = "Epson_ET_3950";
    ensurePrinters = [
      {
        name = "Epson_ET_3950";
        description = "Epson EcoTank ET-3950";
        location = "Home";
        deviceUri = "ipp://192.168.1.191/ipp/print";
        model = "everywhere";
        ppdOptions.PageSize = "A4";
      }
    ];
  };

  # sane-airscan discovers the scanner's open eSCL interface over mDNS. Avoid
  # loading SANE's second eSCL implementation, which can duplicate devices.
  hardware.sane = {
    enable = true;
    extraBackends = [
      pkgs.sane-airscan
      (lib.hiPrio airscanConfig)
    ];
    disabledDefaultBackends = [ "escl" ];
  };

  environment.systemPackages = with pkgs; [
    sane-airscan
    sane-backends
  ];
}
