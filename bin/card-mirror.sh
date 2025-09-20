#!/bin/zsh
#
# card-mirror.sh — Fast per-card mirror with Attic (quarantine) + tombstones + manifest
# Mirrors a card to CardMirror/<CardID>/, moves deletions/overwrites into Attic/YYYY-MM-DD/.
# Supports per-card .tombstones (exclude list) so NAS-side culls won't be re-copied from the card.
#
set -euo pipefail
setopt EXTENDED_GLOB NO_CASE_GLOB
IFS=$'\n\t'

# Script directory and repo root for config loading
SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# Load optional config overrides
[[ -f "$REPO_ROOT/config/config.sh" ]] && source "$REPO_ROOT/config/config.sh"

# Set defaults (can be overridden by config or environment)
: "${DEST_ROOT:="/Volumes/Extreme SSD/PhotoVault/CardMirror"}"
: "${KEEP_DAYS:=90}"
: "${FAST_MODE:=1}"  # Adds -W --omit-dir-times for speed on local disks
: "${DRY_RUN:=0}"    # DRY_RUN=1 to see what would happen

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*"; }
die() { echo "[$(timestamp)] ERROR: $*" >&2; exit 1; }

# Verify destination is accessible (create parent if needed)
if [[ ! -d "$DEST_ROOT" ]]; then
  log "Destination not found, attempting to create: $DEST_ROOT"
  mkdir -p "$DEST_ROOT" || die "Cannot create destination: $DEST_ROOT"
fi
need() { command -v "$1" >/dev/null 2>&1 || die "Missing '$1'"; }
need rsync

# --- Detect source (card) ---
# Only consider EXTERNAL/REMOVABLE camera-like FAT/exFAT volumes; skip destination drive
SRC="${1:-}"
# Get destination volume root to avoid mirroring to same drive
# Try to get the actual volume mount point, fallback to path-based detection
dest_vol_root=""
if [[ "$DEST_ROOT" == /Volumes/* ]]; then
  dest_vol_root="$(echo "$DEST_ROOT" | cut -d/ -f1-3)"  # /Volumes/VolumeName
else
  dest_vol_root="$(dirname "$(dirname "$DEST_ROOT")")"  # fallback
fi
is_external() { diskutil info "$1" 2>/dev/null | grep -E "External:\s*Yes|Device Location:\s*External|Removable Media:\s*Yes" >/dev/null; }
is_camera_tree() { [[ -d "$1/DCIM" || -d "$1/PRIVATE" || -d "$1/AVCHD" ]]; }
is_card_fs() { diskutil info "$1" 2>/dev/null | grep -E "File System Personality:\s*(ExFAT|MS-DOS \(FAT[0-9]*\))" >/dev/null; }

if [[ -z "${SRC}" ]]; then
  candidates=()
  for v in /Volumes/*; do
    [[ -d "$v" ]] || continue
    [[ "$v" == "$dest_vol_root" ]] && continue
    [[ "$(basename "$v")" == "Macintosh HD" ]] && continue
    is_external "$v" || continue
    is_camera_tree "$v" || continue
    is_card_fs "$v" || continue
    candidates+=("$v")
  done

  if (( ${#candidates[@]} == 0 )); then
    die "No external camera card found. Pass the source explicitly, e.g. /Volumes/SD-A01"
  elif (( ${#candidates[@]} > 1 )); then
    echo "Multiple card-like volumes found:"
    for c in "${candidates[@]}"; do echo "  - $c"; done
    die "Please run again with an explicit source path."
  else
    SRC="${candidates[1]:-}"; [[ -n "$SRC" ]] || die "Internal error: empty candidate after detection"
    log "Auto-detected source: $SRC"
  fi
fi

[[ -n "${SRC}" && -d "${SRC}" ]] || die "Source not found: $SRC"

# Prefer stable ID from CARD_ID.txt if present; else use volume label
CARD_LABEL="$(basename "$SRC")"
if [[ -f "$SRC/CARD_ID.txt" ]]; then
  CARD_ID="$(awk -F= '/^CARD_ID=/{print $2}' "$SRC/CARD_ID.txt" | tr -d '\r\n')"
  [[ -n "$CARD_ID" ]] || CARD_ID="$CARD_LABEL"
else
  CARD_ID="$CARD_LABEL"
fi
CARD_ID="${CARD_ID//[^A-Za-z0-9._-]/-}"   # sanitize

DEST="$DEST_ROOT/$CARD_ID"
ATTIC="$DEST/Attic/$(date +%F)"
mkdir -p "$DEST" "$ATTIC"

# Marker file
if [[ ! -f "$DEST/CARD_ID.txt" ]]; then
  { echo "CARD_ID=$CARD_ID"; echo "Created=$(date -u +%FT%TZ)"; } > "$DEST/CARD_ID.txt"
fi

# --- Rsync mirror with Attic and tombstones ---
log "Mirroring from '$SRC'  →  '$DEST'"
log "Quarantining deletes/overwrites to: $ATTIC"

RSYNC_FLAGS=(-a -m --info=progress2 --partial --modify-window=2 --no-compress
             --exclude ".Spotlight-V100" --exclude ".Trashes" --exclude ".fseventsd" --exclude ".TemporaryItems"
             --exclude "._*"
             --filter 'protect Attic/' --filter 'protect Attic/***'
             --delete
             --backup
             --backup-dir="$ATTIC")
[[ -f "$DEST/.tombstones" ]] && RSYNC_FLAGS+=(--exclude-from="$DEST/.tombstones")
[[ "$FAST_MODE" == "1" ]] && RSYNC_FLAGS+=(-W --omit-dir-times)
[[ "$DRY_RUN" == "1" ]] && RSYNC_FLAGS+=(-n)

rsync "${RSYNC_FLAGS[@]}" "$SRC"/ "$DEST"/

# Update manifest of mirrored files (relative paths), excluding Attic and system files
MANIFEST="$DEST/.manifest-last.txt"
find "$DEST" -type f -print 2>/dev/null | \
  grep -v "/Attic/" | \
  grep -E -v "^$DEST/\\..*$" | \
  sed -e "s#^$DEST/##" | \
  sort > "$MANIFEST"

# --- Prune old Attic folders ---
if [[ -d "$DEST/Attic" && "$KEEP_DAYS" -gt 0 ]]; then
  log "Pruning Attic folders older than $KEEP_DAYS days"
  find "$DEST/Attic" -type d -mindepth 1 -maxdepth 1 -mtime +$KEEP_DAYS -exec rm -rf {} + 2>/dev/null || true
fi

log "Mirror complete for card: $CARD_ID"
