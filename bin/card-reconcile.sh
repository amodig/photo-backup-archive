#!/usr/bin/env bash
# card-reconcile.sh — Tombstone reconciliation (archive deletes + FastRawViewer rejects)
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

touch "$TOMBSTONES"
CURRENT=$(mktemp)
TMP=$(mktemp)
trap 'rm -f "$CURRENT" "$TMP"' EXIT

platform_list_keeper_rels "$DEST" "$ATTIC_FOLDER" "$REJECTED_FOLDER" | sort > "$CURRENT"
DELETED=$(comm -23 "$MANIFEST" "$CURRENT" || true)

manifest_deleted=0
if [[ -n "$DELETED" ]]; then
  manifest_deleted=$(wc -l <<< "$DELETED" | tr -d ' ')
  cp "$TOMBSTONES" "$TMP"
  awk '{print "/"$0}' <<< "$DELETED" >> "$TMP"
  sort -u "$TMP" -o "$TOMBSTONES"
  log "Tombstoned ${manifest_deleted} path(s) removed from the archive (vs last manifest)."
else
  log "No archive-side deletions detected vs last manifest."
fi

frv_in_rejected="$(platform_tombstone_frv_rejects "$DEST" "$REJECTED_FOLDER" "$TOMBSTONES")"
if (( frv_in_rejected > 0 )); then
  log "FastRawViewer: indexed ${frv_in_rejected} file(s) under ${REJECTED_FOLDER}; keeper paths added to .tombstones."
else
  log "FastRawViewer: no files under ${REJECTED_FOLDER}."
fi

sidecar_added="$(platform_tombstone_expand_companion_sidecars "$TOMBSTONES")"
if (( sidecar_added > 0 )); then
  log "Companion sidecars: added ${sidecar_added} predicted path(s) (same stem as tombstoned raws)."
fi

tombstone_total=$(wc -l < "$TOMBSTONES" | tr -d ' ')
if (( manifest_deleted == 0 && frv_in_rejected == 0 && sidecar_added == 0 )); then
  log "Nothing new to tombstone."
  exit 0
fi

log "Tombstone file now has ${tombstone_total} path(s). Next mirror will skip them on the card."

if (( frv_in_rejected > 0 )); then
  log "After review, clear ${REJECTED_FOLDER} in FastRawViewer or delete those folders manually."
fi

log "Tombstone reconciliation complete for card: $CARD_ID"
