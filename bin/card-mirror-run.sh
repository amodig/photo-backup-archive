#!/bin/zsh
set -euo pipefail
setopt EXTENDED_GLOB NO_CASE_GLOB
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# Load optional config overrides
[[ -f "$REPO_ROOT/config/config.sh" ]] && source "$REPO_ROOT/config/config.sh"

: "${DEST_ROOT:="/Volumes/Extreme SSD/PhotoVault/CardMirror"}"
: "${KEEP_DAYS:=90}"
: "${FAST_MODE:=1}"
: "${DRY_RUN:=0}"

exec "$REPO_ROOT/bin/card-mirror.sh"
