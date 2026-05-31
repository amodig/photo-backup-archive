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

platform_rsync_info_flags() {
  # Used only when SHOW_PROGRESS=0 (otherwise rsync stays quiet; script logs progress).
  if rsync --info=help 2>&1 | grep -q 'stats2'; then
    echo --info=stats2
  elif rsync --info=help 2>&1 | grep -q 'progress2'; then
    echo --info=progress2
  else
    echo --progress
  fi
}

platform_format_eta() {
  local sec="$1"
  (( sec < 0 )) && sec=0
  printf '%d:%02d:%02d' $((sec / 3600)) $(((sec % 3600) / 60)) $((sec % 60))
}

# True while pid exists and is not a zombie (rsync may exit before bash reaps it).
platform_pid_running() {
  local pid="$1" st
  [[ -n "$pid" ]] || return 1
  st=$(ps -p "$pid" -o state= 2>/dev/null) || return 1
  st=${st// /}
  [[ -n "$st" && "$st" != "Z" ]]
}

# Set PLATFORM_MIRROR_TICK_MSG and return 0 when a new line should be logged; 1 if skipped.
# Must be called without command substitution — $(...) runs in a subshell and drops state updates.
platform_mirror_progress_tick() {
  local dest="$1" src_kb="$2" src_label="$3" interval="$4"
  local -n _state="$5" # nameref: last_kb last_time last_emit last_pct preparing

  local now dest_kb dest_label pct rate_kb eta_sec
  PLATFORM_MIRROR_TICK_MSG=""
  now=$(date +%s)
  interval="${interval:-15}"
  [[ "$interval" =~ ^[0-9]+$ ]] && (( interval >= 1 )) || interval=15

  if (( _state[last_emit] > 0 && now < _state[last_emit] + interval )); then
    return 1
  fi

  dest_kb="$(du -sk "$dest" 2>/dev/null | awk '{print $1}')"
  dest_kb="${dest_kb:-0}"
  dest_label="$(platform_format_dest_kb "$dest_kb")"

  if (( dest_kb == 0 )); then
    if (( _state[preparing] == 0 )); then
      _state[preparing]=1
      _state[last_emit]=$now
      PLATFORM_MIRROR_TICK_MSG="building file list / starting…"
      return 0
    fi
    return 1
  fi

  src_kb="${src_kb//[!0-9]/}"
  src_kb="${src_kb:-0}"

  pct=0
  if (( src_kb > 0 )); then
    pct=$((dest_kb * 100 / src_kb))
    (( pct > 100 )) && pct=100
  fi

  if (( pct < _state[last_pct] )); then
    return 1
  fi
  if (( pct == _state[last_pct] && _state[last_pct] >= 0 )); then
    return 1
  fi

  PLATFORM_MIRROR_TICK_MSG="${dest_label} / ${src_label} (~${pct}%)"
  if (( _state[last_kb] > 0 && _state[last_time] > 0 && dest_kb > _state[last_kb] && now > _state[last_time] )); then
    rate_kb=$(( (dest_kb - _state[last_kb]) / (now - _state[last_time]) ))
    if (( rate_kb > 0 && dest_kb < src_kb )); then
      eta_sec=$(( (src_kb - dest_kb) / rate_kb ))
      PLATFORM_MIRROR_TICK_MSG+=" | ~$((rate_kb / 1024)) MB/s | ETA $(platform_format_eta "$eta_sec")"
    fi
  fi

  _state[last_kb]=$dest_kb
  _state[last_time]=$now
  _state[last_emit]=$now
  _state[last_pct]=$pct
  if (( pct >= 99 && _state[finalize_started] == 0 )); then
    _state[finalize_started]=$now
  fi
  return 0
}

# Human-readable size from du -sk kilobytes.
platform_format_dest_kb() {
  local dest_kb="$1"
  if (( dest_kb >= 1048576 )); then
    awk "BEGIN { printf \"%.0fG\", ${dest_kb}/1048576 }"
  elif (( dest_kb >= 1024 )); then
    awk "BEGIN { printf \"%.0fM\", ${dest_kb}/1024 }"
  else
    echo "${dest_kb}K"
  fi
}

# Periodic status while rsync is still running after disk size ~100%. Sets PLATFORM_MIRROR_TICK_MSG.
platform_mirror_finalize_heartbeat() {
  local dest="$1" src_label="$2" interval="$3"
  local -n _state="$4"

  local now dest_kb dest_label elapsed
  PLATFORM_MIRROR_TICK_MSG=""
  now=$(date +%s)
  interval="${interval:-15}"
  [[ "$interval" =~ ^[0-9]+$ ]] && (( interval >= 1 )) || interval=15

  if (( _state[last_finalize_emit] > 0 && now < _state[last_finalize_emit] + interval )); then
    return 1
  fi

  dest_kb="$(du -sk "$dest" 2>/dev/null | awk '{print $1}')"
  dest_kb="${dest_kb:-0}"
  dest_label="$(platform_format_dest_kb "$dest_kb")"

  elapsed=0
  if (( _state[finalize_started] > 0 )); then
    elapsed=$((now - _state[finalize_started]))
  fi

  PLATFORM_MIRROR_TICK_MSG="Finalizing rsync: ${dest_label} / ${src_label}"
  if (( elapsed > 0 )); then
    PLATFORM_MIRROR_TICK_MSG+=" (${elapsed}s)"
  fi
  PLATFORM_MIRROR_TICK_MSG+="…"

  _state[last_finalize_emit]=$now
  return 0
}

# True if a relative path should appear in .manifest-last.txt (matches card-mirror filters).
platform_manifest_include_rel() {
  local rel="$1" attic="$2" rejected="$3"
  [[ "$rel" == "${attic}" || "$rel" == "${attic}"/* ]] && return 1
  [[ "$rel" == "${rejected}" || "$rel" == "${rejected}"/* ]] && return 1
  [[ "$rel" != */* && "$rel" == .* ]] && return 1
  return 0
}

# Build sorted manifest; logs scan/sort progress every interval seconds. Sets PLATFORM_MANIFEST_COUNT.
platform_build_card_manifest() {
  local dest="$1" manifest="$2" attic="$3" rejected="$4" interval="$5"
  local tmp count now last_emit rel
  tmp="${manifest}.tmp.$$"
  count=0
  last_emit=0
  interval="${interval:-15}"
  [[ "$interval" =~ ^[0-9]+$ ]] && (( interval >= 1 )) || interval=15

  : >"$tmp"
  while IFS= read -r -d '' f; do
    rel="${f#"${dest}/"}"
    platform_manifest_include_rel "$rel" "$attic" "$rejected" || continue
    printf '%s\n' "$rel" >>"$tmp"
    count=$((count + 1))
    now=$(date +%s)
    if (( last_emit == 0 || now >= last_emit + interval )); then
      echo "MANIFEST_PROGRESS:scanned ~${count} files…"
      last_emit=$now
    fi
  done < <(
    find "$dest" -type f \
      ! -name '._*' ! -name '.DS_Store' \
      -print0 2>/dev/null
  )

  echo "MANIFEST_PROGRESS:sorting ~${count} paths…"
  sort -o "$manifest" "$tmp"
  rm -f "$tmp"
  echo "MANIFEST_COUNT:${count}"
}

platform_measure_source() {
  local src="$1"
  local count size_kb size_h
  count="$(find "$src" -type f ! -name '._*' ! -name '.DS_Store' 2>/dev/null | wc -l | tr -d ' ')"
  size_kb="$(du -sk "$src" 2>/dev/null | awk '{print $1}')"
  size_h="$(du -sh "$src" 2>/dev/null | awk '{print $1}')"
  printf '%s\t%s\t%s\n' "${size_kb:-0}" "${size_h:-?}" "${count:-0}"
}
