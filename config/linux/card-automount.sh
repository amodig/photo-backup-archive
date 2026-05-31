#!/usr/bin/env bash
# card-automount.sh — headless USB/MMC camera-card mount helper (installed by install-linux-card-mount.sh)
set -euo pipefail

[[ -f /etc/default/card-automount ]] && source /etc/default/card-automount

MOUNT_USER="${MOUNT_USER:-}"
MOUNT_ROOT="${MOUNT_ROOT:-/media/${MOUNT_USER}}"
LOG_TAG="card-automount"

log() { logger -t "$LOG_TAG" "$*"; echo "[${LOG_TAG}] $*"; }

# udev %E{ID_FS_LABEL} escapes spaces/special chars (e.g. \x20) — decode before path use.
decode_udev_label() {
  python3 - "$1" <<'PY'
import sys
print(sys.argv[1].encode("utf-8").decode("unicode_escape"))
PY
}

need_mount_user() {
  [[ -n "$MOUNT_USER" ]] || {
    log "MOUNT_USER unset — re-run: sudo ./bin/install-linux-card-mount.sh"
    exit 1
  }
}

mount_dev() {
  local dev="$1"
  local node="/dev/${dev}"
  local label fstype mountpoint uid gid

  need_mount_user
  [[ -b "$node" ]] || { log "skip: not a block device: $node"; exit 0; }

  if findmnt -n "$node" >/dev/null 2>&1; then
    log "already mounted: $node"
    exit 0
  fi

  label="$(blkid -o value -s LABEL "$node" 2>/dev/null || true)"
  fstype="$(blkid -o value -s TYPE "$node" 2>/dev/null || true)"

  [[ -n "$label" ]] || { log "skip: no filesystem label on $node"; exit 0; }
  [[ "$fstype" =~ ^(exfat|vfat|msdos|fat)$ ]] || {
    log "skip: unsupported fstype '$fstype' on $node"
    exit 0
  }

  mountpoint="${MOUNT_ROOT}/${label}"
  uid="$(id -u "$MOUNT_USER" 2>/dev/null || echo 1000)"
  gid="$(id -g "$MOUNT_USER" 2>/dev/null || echo 1000)"

  mkdir -p "$mountpoint"
  mount -o "uid=${uid},gid=${gid},umask=022" "$node" "$mountpoint"

  if [[ ! -d "$mountpoint/DCIM" && ! -d "$mountpoint/PRIVATE" && ! -d "$mountpoint/AVCHD" ]]; then
    umount "$mountpoint" 2>/dev/null || true
    rmdir "$mountpoint" 2>/dev/null || true
    log "skip: no camera tree on $node (label=$label)"
    exit 0
  fi

  log "mounted $node at $mountpoint (fstype=$fstype label=$label)"
}

umount_dev() {
  local dev="$1"
  local node="/dev/${dev}"
  local target

  target="$(findmnt -n -o TARGET --source "$node" 2>/dev/null || true)"
  [[ -n "$target" ]] || { log "not mounted: $node"; exit 0; }

  umount "$target"
  rmdir "$target" 2>/dev/null || true
  log "unmounted $node from $target"
}

umount_by_label() {
  local label="$1"
  local mountpoint

  need_mount_user
  label="$(decode_udev_label "$label")"
  mountpoint="${MOUNT_ROOT}/${label}"
  [[ -d "$mountpoint" ]] || { log "no mountpoint for label $label"; exit 0; }
  findmnt -n "$mountpoint" >/dev/null 2>&1 || { log "not mounted: $mountpoint"; exit 0; }

  umount "$mountpoint"
  rmdir "$mountpoint" 2>/dev/null || true
  log "unmounted $mountpoint (label=$label)"
}

case "${1:-}" in
  add)              mount_dev "${2:?device name required, e.g. sda1}" ;;
  remove)           umount_dev "${2:?device name required, e.g. sda1}" ;;
  remove-by-label)  umount_by_label "${2:?label required, e.g. A2408A}" ;;
  *)
    echo "Usage: $0 add|remove <device> | remove-by-label <label>" >&2
    exit 2
    ;;
esac
