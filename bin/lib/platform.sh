# platform.sh — macOS and Linux helpers for card-mirror scripts
# shellcheck shell=bash

platform_os() { uname -s 2>/dev/null || echo unknown; }

# Default DEST_ROOT when unset (override in config/config.sh)
platform_default_dest_root() {
  case "$(platform_os)" in
    Darwin) echo "/Volumes/Extreme SSD/PhotoVault/CardMirror" ;;
    Linux)  echo "${CARD_MIRROR_DEST_LINUX:-/mnt/PhotoVault/CardMirror}" ;; # NAS share mount path on this host
    *)      echo "${HOME}/PhotoVault/CardMirror" ;;
  esac
}

# Mount point containing DEST_ROOT (exclude from card auto-detect)
platform_dest_volume_root() {
  local dest_root="$1"
  case "$(platform_os)" in
    Darwin)
      if [[ "$dest_root" == /Volumes/* ]]; then
        echo "$dest_root" | cut -d/ -f1-3
        return
      fi
      ;;
    Linux)
      if command -v findmnt >/dev/null 2>&1; then
        findmnt -n -o TARGET --target "$dest_root" 2>/dev/null && return
      fi
      ;;
  esac
  dirname "$(dirname "$dest_root")"
}

platform_is_camera_tree() {
  [[ -d "$1/DCIM" || -d "$1/PRIVATE" || -d "$1/AVCHD" ]]
}

platform_is_card_fs() {
  local mount="$1"
  case "$(platform_os)" in
    Darwin)
      diskutil info "$mount" 2>/dev/null | grep -E "File System Personality:\s*(ExFAT|MS-DOS \(FAT[0-9]*\))" >/dev/null
      ;;
    Linux)
      local fstype
      fstype="$(findmnt -n -o FSTYPE --target "$mount" 2>/dev/null || true)"
      [[ "$fstype" =~ ^(vfat|exfat|msdos|fat|fuseblk)$ ]]
      ;;
    *)
      return 1
      ;;
  esac
}

platform_is_external_removable() {
  local mount="$1"
  case "$(platform_os)" in
    Darwin)
      diskutil info "$mount" 2>/dev/null | grep -E "External:\s*Yes|Device Location:\s*External|Removable Media:\s*Yes" >/dev/null
      ;;
    Linux)
      local src base block removable
      src="$(findmnt -n -o SOURCE --target "$mount" 2>/dev/null | sed 's/\[.*\]//' || true)"
      [[ -n "$src" ]] || return 1
      base="$(basename "$src")"
      base="${base%%[0-9]*}"
      [[ -n "$base" ]] || return 1
      if [[ -r "/sys/block/${base}/removable" ]]; then
        removable="$(cat "/sys/block/${base}/removable" 2>/dev/null)"
        [[ "$removable" == "1" ]] && return 0
      fi
      # USB / MMC readers often show TRAN=usb or sd
      if command -v lsblk >/dev/null 2>&1; then
        lsblk -dn -o NAME,RM,TRAN 2>/dev/null | awk -v b="$base" '$1==b && ($2=="1" || $3=="usb")' | grep -q .
        return $?
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# Append candidate mount paths to array name passed as $1
platform_collect_card_mounts() {
  local -n _out=$1
  local dest_vol_root="$2"
  local root v

  case "$(platform_os)" in
    Darwin)
      for v in /Volumes/*; do
        [[ -d "$v" ]] || continue
        [[ "$v" == "$dest_vol_root" ]] && continue
        [[ "$(basename "$v")" == "Macintosh HD" ]] && continue
        _out+=("$v")
      done
      ;;
    Linux)
      local roots=()
      [[ -n "${CARD_MOUNT_ROOTS:-}" ]] && IFS=: read -r -a roots <<< "$CARD_MOUNT_ROOTS"
      if ((${#roots[@]} == 0)); then
        roots=(/media/"${USER:-root}" /run/media/"${USER:-root}" /mnt)
      fi
      for root in "${roots[@]}"; do
        [[ -d "$root" ]] || continue
        # /media/user/LABEL
        for v in "$root"/*; do
          [[ -d "$v" ]] || continue
          [[ "$v" == "$dest_vol_root" ]] && continue
          _out+=("$v")
        done
        # /media/user (single-level card at root — uncommon)
        if platform_is_camera_tree "$root" && [[ "$root" != "$dest_vol_root" ]]; then
          _out+=("$root")
        fi
      done
      ;;
  esac
}

platform_manifest_mtime() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo 0
    return
  fi
  case "$(platform_os)" in
    Darwin) stat -f %m "$file" 2>/dev/null || echo 0 ;;
    *)      stat -c %Y "$file" 2>/dev/null || echo 0 ;;
  esac
}

platform_format_mtime() {
  local epoch="$1"
  case "$(platform_os)" in
    Darwin) date -r "$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown" ;;
    *)      date -d "@$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown" ;;
  esac
}

platform_rsync_progress_flag() {
  if rsync --info=help 2>&1 | grep -q 'progress2'; then
    echo --info=progress2
  else
    echo --progress
  fi
}

# NFS (and similar remote FS) often reject chgrp/chown; rsync -a then exits 23.
platform_dest_is_nfs() {
  local path="$1"
  case "$(platform_os)" in
    Linux)
      command -v findmnt >/dev/null 2>&1 || return 1
      findmnt -n -o FSTYPE --target "$path" 2>/dev/null | grep -qE '^(nfs|nfs4|cifs|smb|smb3)$'
      ;;
    Darwin)
      mount | grep -F " on ${path}/" | grep -qE 'smbfs|afpfs|nfs'
      ;;
    *) return 1 ;;
  esac
}
