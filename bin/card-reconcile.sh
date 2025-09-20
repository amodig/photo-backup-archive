#!/bin/zsh
# card-reconcile.sh — Smart tombstone reconciliation
# Auto-detects most recent card OR processes specified card
# Usage: ./card-reconcile.sh [CARD_ID] [DEST_ROOT]
set -euo pipefail
setopt EXTENDED_GLOB NO_CASE_GLOB
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# Load optional config overrides
[[ -f "$REPO_ROOT/config/config.sh" ]] && source "$REPO_ROOT/config/config.sh"

# Parse arguments
SPECIFIED_CARD="${1:-}"
DEST_ROOT="${2:-${DEST_ROOT:-/Volumes/Extreme SSD/PhotoVault/CardMirror}}"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*"; }
die() { echo "[$(timestamp)] ERROR: $*" >&2; exit 1; }

[[ -d "$DEST_ROOT" ]] || die "Destination root not found: $DEST_ROOT"

# Determine which card to process
if [[ -n "$SPECIFIED_CARD" ]]; then
  # Card ID specified - use it directly
  CARD_ID="$SPECIFIED_CARD"
  log "Processing specified card: $CARD_ID"
else
  # Auto-detect most recent card
  log "Looking for most recently mirrored card in: $DEST_ROOT"
  
  RECENT_CARD=""
  RECENT_TIME=0
  
  for card_dir in "$DEST_ROOT"/*; do
    [[ -d "$card_dir" ]] || continue
    manifest="$card_dir/.manifest-last.txt"
    [[ -f "$manifest" ]] || continue
    
    card_id="${card_dir##*/}"
    # Use cross-platform stat approach
    if [[ "$OSTYPE" == "darwin"* ]]; then
      mod_time=$(stat -f %m "$manifest" 2>/dev/null || echo 0)
    else
      mod_time=$(stat -c %Y "$manifest" 2>/dev/null || echo 0)
    fi
    
    if (( mod_time > RECENT_TIME )); then
      RECENT_TIME=$mod_time
      RECENT_CARD="$card_id"
    fi
  done
  
  if [[ -z "$RECENT_CARD" ]]; then
    die "No cards found with manifests. Mirror a card first with: ./bin/card-mirror.sh"
  fi
  
  CARD_ID="$RECENT_CARD"
  log "Most recently mirrored card: $CARD_ID"
  log "Last mirrored: $(date -r $RECENT_TIME '+%Y-%m-%d %H:%M:%S')"
fi

# Process the card
DEST="$DEST_ROOT/$CARD_ID"
MANIFEST="$DEST/.manifest-last.txt"
TOMBSTONES="$DEST/.tombstones"

[[ -d "$DEST" ]] || die "No mirror found at $DEST"
[[ -f "$MANIFEST" ]] || die "No manifest at $MANIFEST (run a mirror once first)"

log "Running tombstone reconciliation for: $CARD_ID"

# Current file list (relative paths), excluding Attic
CURRENT=$(mktemp)
trap 'rm -f "$CURRENT"' EXIT
find "$DEST" -type f -print 2>/dev/null | grep -v "/Attic/" | sed -e "s#^$DEST/##" | sort > "$CURRENT"

# Lines present in MANIFEST but not in CURRENT are files you deleted on NAS
DELETED=$(comm -23 "$MANIFEST" "$CURRENT" || true)

if [[ -z "$DELETED" ]]; then
  log "No NAS-side deletions detected to tombstone."
  exit 0
fi

# Append to .tombstones with leading / anchors; avoid duplicates
touch "$TOMBSTONES"
TMP=$(mktemp); trap 'rm -f "$TMP" "$CURRENT"' EXIT
awk '{print "/"$0}' <<< "$DELETED" >> "$TOMBSTONES"
sort -u "$TOMBSTONES" > "$TMP" && mv "$TMP" "$TOMBSTONES"

COUNT=$(wc -l <<< "$DELETED" | tr -d ' ')
log "Tombstoned $COUNT path(s). They will NOT be re-copied from the card on the next mirror."

# Note: Tombstoned files may still exist in Attic folders
# They will be cleaned up automatically after KEEP_DAYS by the normal mirror process
# This preserves the safety net - you can still recover files for KEEP_DAYS period

log "Tombstone reconciliation complete for card: $CARD_ID"
