{ lib, pkgs, ... }:
{
  # Conservative idle-power policy for the i3-10100, SATA mirror, NVMe, and Arc
  # A380. These settings use advertised hardware capabilities and never force
  # unsupported PCIe power states.
  powerManagement = {
    enable = true;
    # With active intel_pstate, "powersave" remains demand-responsive; it does
    # not pin the CPU to its minimum frequency.
    cpuFreqGovernor = lib.mkDefault "powersave";
    # Powertop also places idle-capable PCI/USB devices into automatic runtime
    # power management. Disable this first if a peripheral becomes unreliable.
    powertop.enable = true;
    scsiLinkPolicy = "med_power_with_dipm";
  };

  # thermald protects Intel boost and cooling behavior without a desktop daemon.
  services.thermald.enable = true;

  # C-states are enabled by the kernel by default. Do not set max_cstate limits:
  # such limits disable deeper states rather than enabling them.
  boot.kernelParams = [
    "intel_pstate=active"
    "pcie_aspm.policy=powersupersave"
  ];

  # These save a little power without forcing PCIe ASPM on hardware that did not
  # advertise it. See README.md before considering pcie_aspm=force.
  boot.extraModprobeConfig = ''
    options snd_hda_intel power_save=1 power_save_controller=Y
  '';

  # Apply the most power-focused EPP exposed by active intel_pstate after the
  # kernel creates its per-CPU policy files.
  systemd.services.argon-energy-policy = {
    description = "Set Intel energy/performance preference to power";
    wantedBy = [ "multi-user.target" ];
    after = [ "cpufreq.service" ];
    wants = [ "cpufreq.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      shopt -s nullglob
      for preference in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        echo power > "$preference" || true
      done
    '';
  };
}
