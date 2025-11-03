#!/bin/bash
set -Eeuo pipefail

# Run with: sudo ./uninstall.sh
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Please run as root (e.g., sudo ./uninstall.sh)"; exit 1
fi

DEST_SCRIPT="/usr/local/sbin/swarm-backup.sh"
DEST_CONF="/etc/swarm-backup.conf"
DEST_SERVICE="/etc/systemd/system/swarm-backup.service"
DEST_TIMER="/etc/systemd/system/swarm-backup.timer"

if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now swarm-backup.timer 2>/dev/null || true
  systemctl stop swarm-backup.service 2>/dev/null || true
fi

rm -f "$DEST_TIMER" "$DEST_SERVICE" "$DEST_SCRIPT" "$DEST_CONF" || true

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
fi

echo "Swarm backup script successfully uninstalled."
