#!/bin/zsh
#
# card-mirror.sh — Fast per-card mirror with an Attic for deletes/overwrites
# - Mirrors a card to CardMirror/<CardID>/ using rsync
# - Anything that would be DELETED or OVERWRITTEN is moved to Attic/YYYY-MM-DD/ (quarantine)
# - Keeps last KEEP_DAYS worth of Attic folders (default 90)
# - Uses the card's volume label (rename your cards once: diskutil rename /Volumes/UNTITLED SD-A01)
#
# macOS zsh. Dependencies: rsync
#
set -e
set -u
set -o pipefail
setopt EXTENDED_GLOB NO_CASE_GLOB
IFS=$'\n\t'

DEST_ROOT="${DEST_ROOT:-/Volumes/Extreme SSD/PhotoVault/CardMirror}"
KEEP_DAYS="${KEEP_DAYS:-90}"
FAST_MODE="${FAST_MODE:-1}"          # Adds -W --omit-dir-times for speed on local disks
DRY_RUN="${DRY_RUN:-0}"              # DRY_RUN=1 to see what would happen

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*"; }
die() { echo "[$(timestamp)] ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing '$1'"; }
need rsync

# --- Detect source (card) ---
# Safer auto-detect: only consider EXTERNAL/REMOVABLE volumes with camera folders (DCIM/PRIVATE/AVCHD),
# and never pick the vault's own volume. If multiple candidates exist, list and exit.
SRC="${1:-}"

dest_vol_root="$(dirname "$(dirname "$DEST_ROOT")")"  # e.g., /Volumes/Extreme SSD

is_external() { diskutil info "$1" 2>/dev/null | grep -E "External:\s*Yes|Device Location:\s*External|Removable Media:\s*Yes" >/dev/null; }
is_camera_tree() { [[ -d "$1/DCIM" || -d "$1/PRIVATE" || -d "$1/AVCHD" ]]; }
is_card_fs() { diskutil info "$1" 2>/dev/null | grep -E "File System Personality:\s*(ExFAT|MS-DOS \(FAT[0-9]*\))" >/dev/null; }

if [[ -z "${SRC}" ]]; then
  candidates=()
  for v in /Volumes/*; do
    [[ -d "$v" ]] || continue
    [[ "$v" == "$dest_vol_root" ]] && continue              # skip our destination drive
    [[ "$(basename "$v")" == "Macintosh HD" ]] && continue  # skip system volume by name
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
    SRC="${candidates[1]:-}"
    [[ -n "$SRC" ]] || die "Internal error: empty candidate after detection"
  fi
fi

log "Auto-detected source: $SRC"
[[ -n "${SRC}" && -d "${SRC}" ]] || die "Source not found: $SRC"
CARD_LABEL="$(basename "$SRC")"
CARD_ID="${CARD_LABEL//[^A-Za-z0-9._-]/-}"   # sanitize -> folder-safe

DEST="$DEST_ROOT/$CARD_ID"
ATTIC="$DEST/Attic/$(date +%F)"
mkdir -p "$DEST" "$ATTIC"

# Optional marker file for human sanity
if [[ ! -f "$DEST/CARD_ID.txt" ]]; then
  {
    echo "CARD_ID=$CARD_ID"
    echo "Created=$(date -u +%FT%TZ)"
  } > "$DEST/CARD_ID.txt"
fi

# --- Rsync mirror with Attic for deletes/overwrites ---
log "Mirroring from '$SRC'  →  '$DEST'"
log "Quarantining deletes/overwrites to: $ATTIC"

RSYNC_FLAGS=(-a -m --info=progress2 --partial --modify-window=2 --no-compress
             --exclude ".Spotlight-V100" --exclude ".Trashes" --exclude ".fseventsd" --exclude ".TemporaryItems"
             --exclude "._*"            # AppleDouble metadata
             --filter 'protect Attic/' --filter 'protect Attic/***'  # never delete/prune Attic
             --delete                   # make destination match source
             --backup                   # but keep anything removed/overwritten
             --backup-dir="$ATTIC")
[[ "$FAST_MODE" == "1" ]] && RSYNC_FLAGS+=(-W --omit-dir-times)
[[ "$DRY_RUN" == "1" ]] && RSYNC_FLAGS+=(-n)

# Important: trailing slashes mirror directory contents
rsync "${RSYNC_FLAGS[@]}" "$SRC"/ "$DEST"/

# --- Prune old Attic folders ---
if [[ -d "$DEST/Attic" && "$KEEP_DAYS" -gt 0 ]]; then
  log "Pruning Attic folders older than $KEEP_DAYS days"
  # Only prune subdirs; keep today's folder we just used
  find "$DEST/Attic" -type d -mindepth 1 -maxdepth 1 -mtime +$KEEP_DAYS -exec rm -rf {} + 2>/dev/null || true
fi

log "Mirror complete for card: $CARD_ID"
