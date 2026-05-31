#!/usr/bin/env bash
#
# card-mirror.sh — Fast per-card mirror with Attic (quarantine) + tombstones + manifest
# Mirrors a card to CardMirror/<CardID>/, moves deletions/overwrites into Attic/.
# Supports per-card .tombstones (exclude list) so NAS-side culls won't be re-copied from the card.
#
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=lib/platform.sh
source "$SCRIPT_DIR/lib/platform.sh"

[[ -f "$REPO_ROOT/config/config.sh" ]] && source "$REPO_ROOT/config/config.sh"

: "${DEST_ROOT:=$(platform_default_dest_root)}"
: "${KEEP_DAYS:=90}"
: "${FAST_MODE:=1}"
: "${DRY_RUN:=0}"
: "${ATTIC_FOLDER:="_Attic"}"
: "${REJECTED_FOLDER:="_Rejected"}"
: "${SHOW_PROGRESS:=1}"       # 0 = rsync default output only
: "${PROGRESS_INTERVAL:=15}"  # seconds between progress log lines (minimum 1)

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*"; }
die() { echo "[$(timestamp)] ERROR: $*" >&2; exit 1; }

if [[ ! -d "$DEST_ROOT" ]]; then
  log "Destination not found, attempting to create: $DEST_ROOT"
  mkdir -p "$DEST_ROOT" || die "Cannot create destination: $DEST_ROOT"
fi
need() { command -v "$1" >/dev/null 2>&1 || die "Missing '$1'"; }
need rsync
case "$(platform_os)" in
  Darwin) need diskutil ;;
  Linux)
    need findmnt
    command -v lsblk >/dev/null 2>&1 || log "Note: lsblk not found; removable detection may be weaker"
    ;;
esac

SRC="${1:-}"
dest_vol_root="$(platform_dest_volume_root "$DEST_ROOT")"

if [[ -z "${SRC}" ]]; then
  candidates=()
  mounts=()
  platform_collect_card_mounts mounts "$dest_vol_root"
  for v in "${mounts[@]}"; do
    platform_is_external_removable "$v" || continue
    platform_is_camera_tree "$v" || continue
    platform_is_card_fs "$v" || continue
    candidates+=("$v")
  done

  if ((${#candidates[@]} == 0)); then
    case "$(platform_os)" in
      Darwin) die "No external camera card found. Pass the source explicitly, e.g. /Volumes/A2408A" ;;
      Linux)  die "No external camera card found. Pass the source explicitly, e.g. /media/${USER}/A2408A" ;;
      *)      die "No external camera card found. Pass the source path as the first argument." ;;
    esac
  elif ((${#candidates[@]} > 1)); then
    echo "Multiple card-like volumes found:"
    for c in "${candidates[@]}"; do echo "  - $c"; done
    die "Please run again with an explicit source path."
  else
    SRC="${candidates[0]}"
    log "Auto-detected source: $SRC"
  fi
fi

[[ -n "${SRC}" && -d "${SRC}" ]] || die "Source not found: $SRC"

CARD_LABEL="$(basename "$SRC")"
if [[ -f "$SRC/CARD_ID.txt" ]]; then
  CARD_ID="$(awk -F= '/^CARD_ID=/{print $2}' "$SRC/CARD_ID.txt" | tr -d '\r\n')"
  [[ -n "$CARD_ID" ]] || CARD_ID="$CARD_LABEL"
else
  CARD_ID="$CARD_LABEL"
fi
CARD_ID="${CARD_ID//[^A-Za-z0-9._-]/-}"

DEST="$DEST_ROOT/$CARD_ID"
ATTIC="$DEST/$ATTIC_FOLDER"
mkdir -p "$DEST" "$ATTIC"

if [[ ! -f "$DEST/CARD_ID.txt" ]]; then
  { echo "CARD_ID=$CARD_ID"; echo "Created=$(date -u +%FT%TZ)"; } > "$DEST/CARD_ID.txt"
fi

log "Mirroring from '$SRC'  →  '$DEST'"
log "Quarantining deletes/overwrites to: $ATTIC"
IFS=$'\t' read -r SRC_KB SRC_LABEL SRC_COUNT < <(platform_measure_source "$SRC")
IFS=$'\n\t'
log "Source: ~${SRC_LABEL}, ~${SRC_COUNT} files"

ATTIC_LOG="$ATTIC/.deletion-log.txt"
if [[ -f "$DEST/.manifest-last.txt" ]]; then
  LAST_MANIFEST_DATE="$(platform_format_mtime "$(platform_manifest_mtime "$DEST/.manifest-last.txt")" | cut -d' ' -f1)"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] DELETION DISCOVERY - Last manifest: $LAST_MANIFEST_DATE, Files deleted between $LAST_MANIFEST_DATE and $(date +%Y-%m-%d)" >> "$ATTIC_LOG"
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] INITIAL SYNC - Any files moved to Attic are from pre-existing conditions" >> "$ATTIC_LOG"
fi

RSYNC_FLAGS=(-a -m --partial --modify-window=2 --no-compress
  --exclude ".Spotlight-V100" --exclude ".Trashes" --exclude ".fseventsd" --exclude ".TemporaryItems"
  --exclude "._*" --exclude ".DS_Store"
  --filter "protect $ATTIC_FOLDER/" --filter "protect $ATTIC_FOLDER/***"
  --filter "protect $REJECTED_FOLDER/" --filter "protect $REJECTED_FOLDER/***"
  --delete --backup --backup-dir="$ATTIC")
[[ "$SHOW_PROGRESS" != "1" ]] && RSYNC_FLAGS+=("$(platform_rsync_info_flags)")
[[ -f "$DEST/.tombstones" ]] && RSYNC_FLAGS+=(--exclude-from="$DEST/.tombstones")
[[ "$FAST_MODE" == "1" ]] && RSYNC_FLAGS+=(-W --omit-dir-times)
[[ "$DRY_RUN" == "1" ]] && RSYNC_FLAGS+=(-n)

[[ "$PROGRESS_INTERVAL" =~ ^[0-9]+$ ]] && (( PROGRESS_INTERVAL >= 1 )) || PROGRESS_INTERVAL=15

rsync_status=0
if [[ "$SHOW_PROGRESS" == "1" ]]; then
  log "Starting rsync (quiet; progress line at most every ${PROGRESS_INTERVAL}s when % rises)..."
  declare -A PROGRESS_STATE=(
    [last_kb]=0 [last_time]=0 [last_emit]=0 [last_pct]=-1 [preparing]=0
    [last_finalize_emit]=0 [finalize_started]=0
  )

  rsync "${RSYNC_FLAGS[@]}" "$SRC"/ "$DEST"/ &
  rsync_pid=$!

  while platform_pid_running "$rsync_pid"; do
    if platform_mirror_progress_tick "$DEST" "$SRC_KB" "$SRC_LABEL" "$PROGRESS_INTERVAL" PROGRESS_STATE; then
      log "$PLATFORM_MIRROR_TICK_MSG"
    else
      if (( PROGRESS_STATE[last_pct] >= 99 )) \
        && platform_mirror_finalize_heartbeat "$DEST" "$SRC_LABEL" "$PROGRESS_INTERVAL" PROGRESS_STATE; then
        log "$PLATFORM_MIRROR_TICK_MSG"
      fi
    fi
    platform_pid_running "$rsync_pid" || break
    sleep "$PROGRESS_INTERVAL"
  done

  log "Rsync finished; waiting for exit…"
  if wait "$rsync_pid"; then
    rsync_status=0
  else
    rsync_status=$?
  fi

  if platform_mirror_progress_tick "$DEST" "$SRC_KB" "$SRC_LABEL" "$PROGRESS_INTERVAL" PROGRESS_STATE; then
    log "$PLATFORM_MIRROR_TICK_MSG"
  fi
else
  if ! rsync "${RSYNC_FLAGS[@]}" "$SRC"/ "$DEST"/; then
    rsync_status=$?
  fi
fi
[[ "$rsync_status" -eq 0 ]] || die "rsync failed (exit $rsync_status)"

MANIFEST="$DEST/.manifest-last.txt"
log "Building manifest (scanning mirror)…"
manifest_count=0
while IFS= read -r line; do
  case "$line" in
    MANIFEST_COUNT:*)
      manifest_count="${line#MANIFEST_COUNT:}"
      ;;
    MANIFEST_PROGRESS:*)
      log "${line#MANIFEST_PROGRESS:}"
      ;;
  esac
done < <(platform_build_card_manifest "$DEST" "$MANIFEST" "$ATTIC_FOLDER" "$REJECTED_FOLDER" "$PROGRESS_INTERVAL")
log "Manifest updated (${manifest_count} paths)"

if [[ -d "$ATTIC" && "$KEEP_DAYS" -gt 0 ]]; then
  log "Pruning $ATTIC_FOLDER files older than $KEEP_DAYS days"
  find "$ATTIC" -type f ! -name ".deletion-log.txt" -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true
  find "$ATTIC" -type d -mindepth 1 -empty -delete 2>/dev/null || true
fi

log "Mirror complete for card: $CARD_ID"
