set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo paperless-scan [SOURCE] [DEVICE]

Scan from the first network eSCL/AirScan device and submit one PDF to Paperless.
SOURCE defaults to ADF; use "ADF Duplex" for both sides or Flatbed for the
scanner glass. DEVICE may be an exact value printed by `scanimage -L` when more
than one scanner is present.

Optional environment variables:
  PAPERLESS_SCAN_RESOLUTION  DPI, default 300
  PAPERLESS_SCAN_MODE        Gray or Color, default Gray
EOF
}

if (( $# > 2 )); then
  usage >&2
  exit 2
fi

if (( EUID != 0 )); then
  echo "Run this command through sudo so it can write Paperless's private consume directory." >&2
  exit 1
fi

source_name="${1:-ADF}"
device="${2:-}"
resolution="${PAPERLESS_SCAN_RESOLUTION:-300}"
scan_mode="${PAPERLESS_SCAN_MODE:-Gray}"
consume=/srv/storage/documents/paperless/consume

if [[ ! "$resolution" =~ ^[0-9]+$ ]]; then
  echo "PAPERLESS_SCAN_RESOLUTION must be an integer." >&2
  exit 2
fi

if [[ -z "$device" ]]; then
  device="$(scanimage --formatted-device-list='%d%n' \
    | grep -m1 -E '^(airscan:|escl:https?://)' || true)"
fi

if [[ -z "$device" ]]; then
  echo "No network eSCL scanner found. Run airscan-discover and scanimage -L to diagnose discovery." >&2
  exit 1
fi

if [[ ! -d "$consume" ]]; then
  echo "Paperless consume directory does not exist: $consume" >&2
  exit 1
fi

# Prevent two invocations from feeding the same physical scanner concurrently.
exec 9>/run/lock/paperless-scan.lock
if ! flock -n 9; then
  echo "Another paperless-scan process is already running." >&2
  exit 1
fi

temporary="$(mktemp -d --tmpdir paperless-scan.XXXXXX)"
trap 'rm -rf "$temporary"' EXIT

common_options=(
  --device-name "$device"
  --source "$source_name"
  --resolution "$resolution"
  --mode "$scan_mode"
  --format=png
)

case "${source_name,,}" in
  *flatbed*|*platen*)
    scanimage "${common_options[@]}" >"$temporary/page-0001.png"
    ;;
  *)
    # With an ADF, SANE keeps scanning until the feeder reports that it is
    # empty. The ET-3950 advertises both simplex and duplex source modes.
    scanimage "${common_options[@]}" \
      --batch="$temporary/page-%04d.png" --batch-start=1
    ;;
esac

shopt -s nullglob
pages=("$temporary"/page-*.png)
if (( ${#pages[@]} == 0 )); then
  echo "The scanner returned no pages; nothing was submitted to Paperless." >&2
  exit 1
fi

img2pdf --output "$temporary/document.pdf" "${pages[@]}"

# Rename only after the PDF is complete so Paperless never consumes a partial
# file. Ownership and mode match the NixOS Paperless service account.
timestamp="$(date +%Y%m%d-%H%M%S-%N)"
partial="$consume/.paperless-scan-$timestamp.partial"
target="$consume/scan-$timestamp.pdf"
install -o paperless -g paperless -m 0600 "$temporary/document.pdf" "$partial"
mv "$partial" "$target"

echo "Submitted ${#pages[@]} page(s) to Paperless: $target"
