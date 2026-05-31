#!/usr/bin/env bash
# card-reconcile.sh — Smart tombstone reconciliation
# Auto-detects most recent card OR processes specified card
# Usage: ./card-reconcile.sh [CARD_ID] [DEST_ROOT]
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=lib/platform.sh
source "$SCRIPT_DIR/lib/platform.sh"

[[ -f "$REPO_ROOT/config/config.sh" ]] && source "$REPO_ROOT/config/config.sh"

SPECIFIED_CARD="${1:-}"
DEST_ROOT="${2:-${DEST_ROOT:-$(platform_default_dest_root)}}"

: "${ATTIC_FOLDER:="_Attic"}"
: "${REJECTED_FOLDER:="_Rejected"}"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*"; }
die() { echo "[$(timestamp)] ERROR: $*" >&2; exit 1; }

[[ -d "$DEST_ROOT" ]] || die "Destination root not found: $DEST_ROOT"

if [[ -n "$SPECIFIED_CARD" ]]; then
  CARD_ID="$SPECIFIED_CARD"
  log "Processing specified card: $CARD_ID"
else
  log "Looking for most recently mirrored card in: $DEST_ROOT"

  RECENT_CARD=""
  RECENT_TIME=0

  for card_dir in "$DEST_ROOT"/*; do
    [[ -d "$card_dir" ]] || continue
    manifest="$card_dir/.manifest-last.txt"
    [[ -f "$manifest" ]] || continue

    card_id="${card_dir##*/}"
    mod_time="$(platform_manifest_mtime "$manifest")"

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
  log "Last mirrored: $(platform_format_mtime "$RECENT_TIME")"
fi

DEST="$DEST_ROOT/$CARD_ID"
MANIFEST="$DEST/.manifest-last.txt"
TOMBSTONES="$DEST/.tombstones"

[[ -d "$DEST" ]] || die "No mirror found at $DEST"
[[ -f "$MANIFEST" ]] || die "No manifest at $MANIFEST (run a mirror once first)"

log "Running tombstone reconciliation for: $CARD_ID"

CURRENT=$(mktemp)
trap 'rm -f "$CURRENT"' EXIT
find "$DEST" -type f -print 2>/dev/null | grep -v "/$ATTIC_FOLDER/" | grep -v "/$REJECTED_FOLDER/" | sed -e "s#^$DEST/##" | sort > "$CURRENT"

DELETED=$(comm -23 "$MANIFEST" "$CURRENT" || true)

if [[ -z "$DELETED" ]]; then
  log "No NAS-side deletions detected to tombstone."
  exit 0
fi

touch "$TOMBSTONES"
TMP=$(mktemp)
trap 'rm -f "$TMP" "$CURRENT"' EXIT
awk '{print "/"$0}' <<< "$DELETED" >> "$TOMBSTONES"
sort -u "$TOMBSTONES" > "$TMP" && mv "$TMP" "$TOMBSTONES"

COUNT=$(wc -l <<< "$DELETED" | tr -d ' ')
log "Tombstoned $COUNT path(s). They will NOT be re-copied from the card on the next mirror."

rejected_count=0
while IFS= read -r deleted_file; do
  [[ -n "$deleted_file" ]] || continue
  if find "$DEST" -path "*/$REJECTED_FOLDER/*" -name "$(basename "$deleted_file")" -type f 2>/dev/null | head -1 | grep -q .; then
    rejected_count=$((rejected_count + 1))
  fi
done <<< "$DELETED"

if (( rejected_count > 0 )); then
  log "Found $rejected_count of these files in $REJECTED_FOLDER folders (likely moved during photo culling)"
fi

log "Tombstone reconciliation complete for card: $CARD_ID"
