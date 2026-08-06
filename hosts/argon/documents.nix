{ pkgs, ... }:
let
  # Keep the hardware-facing scan logic in a normal shell file so it can be
  # tested independently. writeShellApplication supplies every runtime tool.
  paperlessScan = pkgs.writeShellApplication {
    name = "paperless-scan";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      img2pdf
      sane-backends
      util-linux
    ];
    text = builtins.readFile ../../scripts/paperless-scan.sh;
  };
in
{
  # Databases and indexes stay on the NVMe; original documents live on RAID.
  # A local PostgreSQL database is easier to back up and restore than SQLite.
  services.paperless = {
    enable = true;
    address = "0.0.0.0";
    port = 28981;
    dataDir = "/var/lib/paperless";
    mediaDir = "/srv/storage/documents/paperless/media";
    consumptionDir = "/srv/storage/documents/paperless/consume";
    database.createLocally = true;
    configureTika = false;

    settings = {
      # Install both OCR language models and prefer German plus English text.
      PAPERLESS_OCR_LANGUAGE = "deu+eng";
      PAPERLESS_CONSUMER_RECURSIVE = true;

      # One worker avoids large OCR bursts competing with media playback and
      # is sufficient for a household document queue.
      PAPERLESS_TASK_WORKERS = 1;
      PAPERLESS_THREADS_PER_WORKER = 1;
    };
  };

  environment.systemPackages = [ paperlessScan ];

  # OCR is batch work: let interactive and media workloads win CPU and disk
  # contention without disabling automatic document processing.
  systemd.services = {
    paperless-consumer.serviceConfig = {
      Nice = 10;
      IOSchedulingClass = "idle";
    };
    paperless-task-queue.serviceConfig = {
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };
}
