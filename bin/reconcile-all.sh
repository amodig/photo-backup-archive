#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=lib/platform.sh
source "$SCRIPT_DIR/lib/platform.sh"

[[ -f "$REPO_ROOT/config/config.sh" ]] && source "$REPO_ROOT/config/config.sh"

: "${DEST_ROOT:=$(platform_default_dest_root)}"

for d in "$DEST_ROOT"/*; do
  [[ -d "$d" ]] || continue
  card_id="${d##*/}"
  "$REPO_ROOT/bin/card-reconcile.sh" "$card_id" "$DEST_ROOT" || true
done
