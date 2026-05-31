#!/usr/bin/env bash
# card-label.sh — Propose CARD_ID from earliest photo EXIF and rename exfat volume (Linux)
#
# Usage:
#   ./bin/card-label.sh I                    # full EXIF scan (~1–3 min on large cards)
#   ./bin/card-label.sh --quick I            # fast: one sample per DCIM folder (~1 sec)
#   ./bin/card-label.sh I /media/amodig/MYDISK
#   DRY_RUN=1 ./bin/card-label.sh --quick I
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=lib/platform.sh
source "$SCRIPT_DIR/lib/platform.sh"

[[ -f "$REPO_ROOT/config/config.sh" ]] && source "$REPO_ROOT/config/config.sh"

: "${DEST_ROOT:=$(platform_default_dest_root)}"
: "${DRY_RUN:=0}"
: "${QUICK:=0}"

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [--quick] <owner-initial> [card-mount-path]

  owner-initial   Single letter, e.g. I for Ida, A for Arttu
  card-mount-path Optional; auto-detects a mounted camera card if omitted
  --quick         Sample EXIF from the first still in each DCIM/* folder (fast, like
                  Finder eyeballing). Default: scan all stills for true earliest date.

Naming: {OwnerInitial}{YYMM}{Sequence} from EXIF DateTimeOriginal in DCIM.
Checks existing folders under DEST_ROOT for the next free sequence letter.

Requires: exiftool (recommended) or python3-pillow; exfatprogs for volume rename.
Mount the card first:  udisksctl mount -b /dev/sdX1
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=1; shift ;;
    -h|--help) usage ;;
    -*) die "Unknown option: $1 (try --help)" ;;
    *) break ;;
  esac
done

OWNER_INITIAL="${1:-}"
SRC="${2:-}"

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

# Stills only (skip MOV/MP4).
STILL_NAME_RE='.*\.(JPG|JPEG|RW2|ORF|ARW|CR2|CR3|NEF|HEIC|TIF|TIFF|jpg|jpeg|rw2|orf|arw|cr2|cr3|nef|heic|tif|tiff)$'

exif_ym_from_files() {
  local -a files=("$@")
  ((${#files[@]})) || return 1
  command -v exiftool >/dev/null 2>&1 || return 1
  set +o pipefail
  exiftool -fast2 -T -DateTimeOriginal -d %y%m "${files[@]}" 2>/dev/null \
    | grep -E '^[0-9]{4}$' | sort -n | head -1
  set -o pipefail
}

pick_sequence() {
  local prefix="$1"
  local letter u
  local -a used=()
  local listing

  listing="$(timeout 10 ls -1 "$DEST_ROOT" 2>/dev/null)" || {
    echo "WARN: Could not list $DEST_ROOT (NFS slow/unmounted?) — assuming sequence A." >&2
    echo "A"
    return 0
  }
  while IFS= read -r name; do
    [[ "$name" =~ ^${prefix}[A-Z]$ ]] && used+=("${name: -1}")
  done <<< "$listing"

  for letter in {A..Z}; do
    for u in "${used[@]}"; do
      [[ "$u" == "$letter" ]] && continue 2
    done
    echo "$letter"
    return 0
  done
  return 1
}

first_still_in_dir() {
  local dir="$1"
  local f
  f="$(find "$dir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' \) 2>/dev/null | sort | head -1)"
  [[ -n "$f" ]] && { echo "$f"; return; }
  find "$dir" -maxdepth 1 -type f -regextype posix-extended -regex "$STILL_NAME_RE" 2>/dev/null \
    | sort | head -1
}

earliest_exif_quick() {
  local dcim="$1"
  local -a samples=()
  local dir f

  echo "Quick EXIF sample (first still per DCIM folder)..." >&2
  while IFS= read -r -d '' dir; do
    f="$(first_still_in_dir "$dir")"
    [[ -n "$f" ]] && samples+=("$f")
  done < <(find "$dcim" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

  if ((${#samples[@]} == 0)); then
    f="$(find "$dcim" -type f -regextype posix-extended -regex "$STILL_NAME_RE" 2>/dev/null | sort | head -1)"
    [[ -n "$f" ]] && samples=("$f")
  fi

  ((${#samples[@]})) || return 1
  echo "  ${#samples[@]} sample file(s)" >&2
  exif_ym_from_files "${samples[@]}"
}

earliest_exif_full() {
  local dcim="$1"
  local -a exts=(JPG JPEG RW2 ORF ARW CR2 CR3 NEF HEIC TIF TIFF)
  local -a ext_args=()
  local e

  if command -v exiftool >/dev/null 2>&1; then
    for e in "${exts[@]}"; do
      ext_args+=(-ext "$e" -ext "${e,,}")
    done
    echo "Full EXIF scan (large cards: 1–3 min)..." >&2
    set +o pipefail
    exiftool -progress -fast2 -T -DateTimeOriginal -d %y%m "${ext_args[@]}" -r "$dcim" \
      | grep -E '^[0-9]{4}$' | sort -n | head -1
    set -o pipefail
    return
  fi
  echo "Scanning EXIF (Pillow, JPEG only)..." >&2
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

if [[ "$QUICK" == "1" ]]; then
  EARLIEST_YM="$(earliest_exif_quick "$SRC/DCIM" | tr -d '\r\n')"
  EXIF_MODE="quick sample (not full card scan)"
else
  EARLIEST_YM="$(earliest_exif_full "$SRC/DCIM" | tr -d '\r\n')"
  EXIF_MODE="full EXIF scan"
fi

[[ -n "$EARLIEST_YM" && "$EARLIEST_YM" =~ ^[0-9]{4}$ ]] || die "No EXIF dates in DCIM. Install exiftool: sudo apt install libimage-exiftool-perl"

PREFIX="${OWNER_INITIAL}${EARLIEST_YM}"
SEQUENCE="$(pick_sequence "$PREFIX")" || die "No free sequence letter for prefix $PREFIX under $DEST_ROOT"

CARD_ID="${PREFIX}${SEQUENCE}"
CURRENT_LABEL="$(findmnt -n -o LABEL --target "$SRC" 2>/dev/null || true)"
[[ -z "$CURRENT_LABEL" || "$CURRENT_LABEL" == "-" ]] && CURRENT_LABEL="$(basename "$SRC")"
DEV="$(findmnt -n -o SOURCE --target "$SRC" 2>/dev/null | sed 's/\[.*\]//' || true)"
DEV="${DEV#/dev/}"

echo "Mount:            $SRC"
echo "Device:           ${DEV:-unknown}"
echo "Current label:    ${CURRENT_LABEL:-<none>}"
echo "Earliest month:   20${EARLIEST_YM:0:2}-${EARLIEST_YM:2:2} (from ${EXIF_MODE})"
echo "Proposed CARD_ID: $CARD_ID"
echo "Mirror dest:      $DEST_ROOT/$CARD_ID"
[[ "$QUICK" == "1" ]] && echo "Note: --quick may differ from a full scan if early shots were deleted or files reordered."

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

echo ""
echo "To rename the volume to $CARD_ID:"
echo "  udisksctl unmount -b /dev/$DEV"
echo "  sudo exfatlabel /dev/$DEV $CARD_ID"
echo "  udisksctl mount -b /dev/$DEV"
echo ""
echo "CARD_ID.txt is on the card — card-mirror.sh will use it even before relabel."

if [[ "${EUID:-$(id -u)}" -eq 0 ]] && ! findmnt -n "/dev/$DEV" >/dev/null 2>&1; then
  exfatlabel "/dev/$DEV" "$CARD_ID"
  echo "Renamed /dev/$DEV → $CARD_ID (device was already unmounted)."
fi
