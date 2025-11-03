#!/bin/bash
set -Eeuo pipefail

# Run with: sudo ./install.sh
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Please run as root (e.g., sudo ./install.sh)"; exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

SRC_SCRIPT="${REPO_DIR}/swarm-backup.sh"
SRC_CONF="${REPO_DIR}/swarm-backup.conf"
SRC_SERVICE="${REPO_DIR}/swarm-backup.service"
SRC_TIMER="${REPO_DIR}/swarm-backup.timer"

DEST_SCRIPT="/usr/local/sbin/swarm-backup.sh"
DEST_CONF="/etc/swarm-backup.conf"
DEST_SERVICE="/etc/systemd/system/swarm-backup.service"
DEST_TIMER="/etc/systemd/system/swarm-backup.timer"

timestamp() { date +%Y%m%d-%H%M%S; }
backup_if_exists() {
  local dest="$1"
  if [[ -e "$dest" ]]; then
    local bak="${dest}.bak.$(timestamp)"
    echo "Backing up existing $(basename "$dest") -> $bak"
    mv -f "$dest" "$bak"
  fi
}

install_file() {
  local src="$1" dest="$2" mode="$3"
  backup_if_exists "$dest"
  install -m "$mode" -o root -g root "$src" "$dest"
  echo "Installed $(basename "$src") -> $dest"
}

# Install main script + config
install_file "$SRC_SCRIPT"  "$DEST_SCRIPT"  0755
install_file "$SRC_CONF"    "$DEST_CONF"    0644

# If systemd is present, install units and enable timer
if command -v systemctl >/dev/null 2>&1; then
  install_file "$SRC_SERVICE" "$DEST_SERVICE" 0644
  install_file "$SRC_TIMER"   "$DEST_TIMER"   0644

  systemctl daemon-reload
  systemctl enable --now swarm-backup.timer
  echo "systemd timer enabled: swarm-backup.timer"
  systemctl status --no-pager swarm-backup.timer || true
else
  echo "systemd not found; skipping service/timer. You can use cron instead."
fi

echo "Done."
echo "Test a run with: sudo systemctl start swarm-backup.service  (or run the script directly)"
