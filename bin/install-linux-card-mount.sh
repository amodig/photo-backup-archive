#!/usr/bin/env bash
# install-linux-card-mount.sh — one-time setup for headless SD card automount on Ubuntu/Linux
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LINUX_CFG="$REPO_ROOT/config/linux"

MOUNT_USER="${MOUNT_USER:-${SUDO_USER:-${USER:-}}}"
INSTALL_POLKIT="${INSTALL_POLKIT:-1}"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Run with sudo: sudo MOUNT_USER=\$USER $0" >&2
    exit 1
  fi
}

need_root

[[ -n "$MOUNT_USER" ]] || {
  echo "Set MOUNT_USER (e.g. sudo MOUNT_USER=amodig $0)" >&2
  exit 1
}

[[ -f "$LINUX_CFG/card-automount.sh" ]] || { echo "Missing $LINUX_CFG/card-automount.sh" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || {
  echo "Install python3 (used by card-automount label decode): sudo apt install python3" >&2
  exit 1
}

echo "Installing headless card automount for user: $MOUNT_USER"

install -m 0755 "$LINUX_CFG/card-automount.sh" /usr/local/sbin/card-automount.sh
install -m 0644 "$LINUX_CFG/99-camera-sd-automount.rules" /etc/udev/rules.d/99-camera-sd-automount.rules

cat > /etc/default/card-automount <<EOF
# Installed by photo-backup-archive/bin/install-linux-card-mount.sh
MOUNT_USER=${MOUNT_USER}
MOUNT_ROOT=/media/${MOUNT_USER}
EOF
chmod 0644 /etc/default/card-automount

mkdir -p "/media/${MOUNT_USER}"
chown "${MOUNT_USER}:${MOUNT_USER}" "/media/${MOUNT_USER}" 2>/dev/null || true

if [[ "$INSTALL_POLKIT" == "1" ]]; then
  install -m 0644 "$LINUX_CFG/50-udisks-mount-plugdev.rules" /etc/polkit-1/rules.d/50-udisks-mount-plugdev.rules
  echo "Installed polkit rule (passwordless udisks mount for plugdev)."
else
  echo "Skipped polkit rule (INSTALL_POLKIT=0)."
fi

udevadm control --reload-rules

echo ""
echo "Done. On insert, labeled exfat/vfat camera cards mount under: /media/${MOUNT_USER}/<LABEL>"
echo "Re-plug the card once to test (or: ls /media/${MOUNT_USER}/)"
echo "Configure mirror dest:     cp config/config.sh.example config/config.sh"
echo "Then mirror:               ./bin/card-mirror.sh"
echo "Logs:                      journalctl -t card-automount -n 20"
