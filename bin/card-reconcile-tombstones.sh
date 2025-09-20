#!/bin/zsh
# card-reconcile-tombstones.sh — Freeze NAS-side culls: add deleted files to .tombstones
# Usage: ./card-reconcile-tombstones.sh <CardID> [DEST_ROOT]
set -euo pipefail
setopt EXTENDED_GLOB NO_CASE_GLOB
IFS=$'\n\t'

CARD_ID="${1:-}"
DEST_ROOT="${2:-/Volumes/Extreme SSD/PhotoVault/CardMirror}"
[[ -n "$CARD_ID" ]] || { echo "Usage: $0 <CardID> [DEST_ROOT]" >&2; exit 2; }

DEST="$DEST_ROOT/$CARD_ID"
MANIFEST="$DEST/.manifest-last.txt"
TOMBSTONES="$DEST/.tombstones"

[[ -d "$DEST" ]] || { echo "No mirror found at $DEST" >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "No manifest at $MANIFEST (run a mirror once first)" >&2; exit 1; }

# Current file list (relative paths), excluding Attic
CURRENT=$(mktemp)
trap 'rm -f "$CURRENT"' EXIT
find "$DEST" -type f -print 2>/dev/null | grep -v "/Attic/" | sed -e "s#^$DEST/##" | sort > "$CURRENT"

# Lines present in MANIFEST but not in CURRENT are files you deleted on NAS
DELETED=$(comm -23 "$MANIFEST" "$CURRENT" || true)

if [[ -z "$DELETED" ]]; then
  echo "No NAS-side deletions detected to tombstone."
  exit 0
fi

# Append to .tombstones with leading / anchors; avoid duplicates
touch "$TOMBSTONES"
TMP=$(mktemp); trap 'rm -f "$TMP" "$CURRENT"' EXIT
awk '{print "/"$0}' <<< "$DELETED" >> "$TOMBSTONES"
sort -u "$TOMBSTONES" > "$TMP" && mv "$TMP" "$TOMBSTONES"

COUNT=$(wc -l <<< "$DELETED" | tr -d ' ')
echo "Tombstoned $COUNT path(s). They will NOT be re-copied from the card on the next mirror."

# Optional: also purge those files from Attic to keep it tidy (comment out to keep)
while IFS= read -r rel; do
  rel="${rel#/}"  # strip leading /
  find "$DEST/Attic" -type f -path "*/$rel" -delete 2>/dev/null || true
done <<< "$DELETED"
