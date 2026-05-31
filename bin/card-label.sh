#!/usr/bin/env bash
# card-label.sh — Propose CARD_ID from earliest photo EXIF and rename exfat volume (Linux)
#
# Usage:
#   ./bin/card-label.sh I              # owner initial Ida → e.g. I2411A
#   ./bin/card-label.sh I /media/amodig/MYDISK
#   DRY_RUN=1 ./bin/card-label.sh I    # print proposal only
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=lib/platform.sh
source "$SCRIPT_DIR/lib/platform.sh"

[[ -f "$REPO_ROOT/config/config.sh" ]] && source "$REPO_ROOT/config/config.sh"

: "${DEST_ROOT:=$(platform_default_dest_root)}"
: "${DRY_RUN:=0}"

OWNER_INITIAL="${1:-}"
SRC="${2:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 <owner-initial> [card-mount-path]

  owner-initial   Single letter, e.g. I for Ida, A for Arttu
  card-mount-path Optional; auto-detects a mounted camera card if omitted

Naming: {OwnerInitial}{YYMM}{Sequence} from earliest EXIF DateTimeOriginal in DCIM.
Checks existing folders under DEST_ROOT for the next free sequence letter.

Requires: exiftool (recommended) or python3-pillow; exfatprogs for volume rename.
Mount the card first:  udisksctl mount -b /dev/sdX1
EOF
  exit 2
}

[[ -n "$OWNER_INITIAL" ]] || usage
[[ "$OWNER_INITIAL" =~ ^[A-Za-z]$ ]] || die "owner-initial must be a single letter"
OWNER_INITIAL="${OWNER_INITIAL^^}"

if [[ -z "$SRC" ]]; then
  candidates=()
  mounts=()
  dest_vol_root="$(platform_dest_volume_root "$DEST_ROOT")"
  platform_collect_card_mounts mounts "$dest_vol_root"
  for v in "${mounts[@]}"; do
    platform_is_external_removable "$v" || continue
    platform_is_camera_tree "$v" || continue
    platform_is_card_fs "$v" || continue
    candidates+=("$v")
  done
  if ((${#candidates[@]} == 0)); then
    die "No mounted camera card found. Mount first: udisksctl mount -b /dev/sdX1"
  elif ((${#candidates[@]} > 1)); then
    echo "Multiple cards found:" >&2
    printf '  %s\n' "${candidates[@]}" >&2
    die "Pass the mount path as the second argument."
  fi
  SRC="${candidates[0]}"
fi

[[ -d "$SRC/DCIM" ]] || die "No DCIM on $SRC — is this a camera card?"
platform_is_card_fs "$SRC" || die "Not a FAT/exFAT mount: $SRC"

earliest_exif() {
  local dcim="$1"
  if command -v exiftool >/dev/null 2>&1; then
    exiftool -T -DateTimeOriginal -d %Y%m -ext JPG -ext jpg -ext ORF -ext orf \
      -ext RW2 -ext ARW -ext CR2 -ext CR3 -ext NEF -ext HEIC -ext MOV -ext MP4 \
      -r "$dcim" 2>/dev/null | sort -n | head -1
    return
  fi
  python3 - "$dcim" <<'PY'
import sys
from pathlib import Path
from datetime import datetime

try:
    from PIL import Image
    from PIL.ExifTags import TAGS
except ImportError:
    sys.exit("")

def exif_datetime(path: Path):
    try:
        with Image.open(path) as im:
            exif = im.getexif()
            if not exif:
                return None
            for tag_id, val in exif.items():
                if TAGS.get(tag_id) == "DateTimeOriginal" and val:
                    return str(val).strip()
    except Exception:
        return None
    return None

dcim = Path(sys.argv[1])
best = None
for path in dcim.rglob("*"):
    if not path.is_file():
        continue
    if path.suffix.upper() not in {".JPG", ".JPEG", ".TIF", ".TIFF", ".HEIC"}:
        continue
    dt = exif_datetime(path)
    if not dt:
        continue
    try:
        parsed = datetime.strptime(dt[:10], "%Y:%m:%d")
    except ValueError:
        continue
    if best is None or parsed < best:
        best = parsed

if best:
    print(best.strftime("%y%m"))
PY
}

EARLIEST_YM="$(earliest_exif "$SRC/DCIM" | tr -d '\r\n')"
[[ -n "$EARLIEST_YM" && "$EARLIEST_YM" =~ ^[0-9]{4}$ ]] || die "No EXIF dates in DCIM. Install exiftool: sudo apt install libimage-exiftool-perl"

PREFIX="${OWNER_INITIAL}${EARLIEST_YM}"
SEQUENCE=""
for letter in {A..Z}; do
  [[ -d "$DEST_ROOT/${PREFIX}${letter}" ]] && continue
  SEQUENCE="$letter"
  break
done
[[ -n "$SEQUENCE" ]] || die "No free sequence letter for prefix $PREFIX under $DEST_ROOT"

CARD_ID="${PREFIX}${SEQUENCE}"
CURRENT_LABEL="$(findmnt -n -o LABEL --target "$SRC" 2>/dev/null || true)"
[[ -z "$CURRENT_LABEL" || "$CURRENT_LABEL" == "-" ]] && CURRENT_LABEL="$(basename "$SRC")"
DEV="$(findmnt -n -o SOURCE --target "$SRC" 2>/dev/null | sed 's/\[.*\]//' || true)"
DEV="${DEV#/dev/}"

echo "Mount:            $SRC"
echo "Device:           ${DEV:-unknown}"
echo "Current label:    ${CURRENT_LABEL:-<none>}"
echo "Earliest month:   20${EARLIEST_YM:0:2}-${EARLIEST_YM:2:2} (from EXIF)"
echo "Proposed CARD_ID: $CARD_ID"
echo "Mirror dest:      $DEST_ROOT/$CARD_ID"

[[ "$DRY_RUN" == "1" ]] && { echo "DRY_RUN=1 — no changes made."; exit 0; }

CARD_ID_FILE="$SRC/CARD_ID.txt"
if [[ ! -f "$CARD_ID_FILE" ]] || ! grep -q "^CARD_ID=${CARD_ID}$" "$CARD_ID_FILE" 2>/dev/null; then
  { echo "CARD_ID=${CARD_ID}"; echo "Created=$(date -u +%FT%TZ)"; } > "$CARD_ID_FILE"
  echo "Wrote $CARD_ID_FILE"
fi

if [[ "$CURRENT_LABEL" == "$CARD_ID" ]]; then
  echo "Volume label already matches."
  exit 0
fi

command -v exfatlabel >/dev/null 2>&1 || die "Install exfatprogs: sudo apt install exfatprogs"
[[ -n "$DEV" ]] || die "Could not resolve block device for $SRC"

echo "Renaming volume to $CARD_ID (umount required)..."
if findmnt -n "$SRC" >/dev/null 2>&1; then
  udisksctl unmount -b "/dev/$DEV" 2>/dev/null || umount "$SRC"
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo ""
  echo "Run these commands to finish the rename:"
  echo "  sudo exfatlabel /dev/$DEV $CARD_ID"
  echo "  udisksctl mount -b /dev/$DEV"
  echo ""
  echo "CARD_ID.txt is already on the card — card-mirror.sh will use it even before relabel."
  exit 0
fi

exfatlabel "/dev/$DEV" "$CARD_ID"
echo "Renamed /dev/$DEV → $CARD_ID"
echo "Mount again: udisksctl mount -b /dev/$DEV"
