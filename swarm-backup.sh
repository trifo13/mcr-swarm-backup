#!/usr/bin/env bash
# swarm-backup.sh
# - Skips on Swarm leader
# - Only one non-leader runs (NFS-safe lock)
# - Optional /etc/swarm-backup.conf + CLI overrides
# - Retention: keep newest N archives

set -Eeuo pipefail

# ---------- Defaults ----------
CONF="/etc/swarm-backup.conf"   # default config file path
BACKUP_DIR="/backup/swarm"      # default backup dir
KEEP="7"                        # default how many to keep
REQUIRE_MOUNTPOINT="0"          # 1=enforce BACKUP_DIR is a mountpoint

# ---------- Helpers ----------
usage() {
  cat <<'USAGE'
Usage: swarm-backup.sh [-c CONFIG] [-d BACKUP_DIR] [-k KEEP] [-h]

Options:
  -c CONFIG      Path to variables file (default: /etc/swarm-backup.conf)
                 May define: BACKUP_DIR=/path, KEEP=number, REQUIRE_MOUNTPOINT=0|1
  -d BACKUP_DIR  Override backup destination directory
  -k KEEP        Override how many recent archives to keep (integer >= 0)
  -h             Show this help

Precedence: CLI > config file > defaults
USAGE
}

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }

SVC_TIMEOUT="${SVC_TIMEOUT:-120}"   # seconds to wait for stop/start

svc_exists() { systemctl list-unit-files 2>/dev/null | grep -q "^$1"; }

wait_until_inactive() {  # $1=unit
  local t="$SVC_TIMEOUT"
  while systemctl is-active --quiet "$1" 2>/dev/null; do
    ((t--)) || { log "timeout stopping $1"; return 1; }
    sleep 1
  done
  return 0
}

wait_until_active() {  # $1=unit
  local t="$SVC_TIMEOUT"
  while ! systemctl is-active --quiet "$1" 2>/dev/null; do
    ((t--)) || { log "timeout starting $1"; return 1; }
    sleep 1
  done
  return 0
}

stop_stack() {
  QUIESCED=0
  # Stop Docker first (it may also stop containerd via deps)
  if svc_exists docker.service && systemctl is-active --quiet docker.service; then
    log "stopping docker.service"
    systemctl stop docker.service
    wait_until_inactive docker.service || return 1
    QUIESCED=1
  fi
  # Then containerd if it still exists/active
  if svc_exists containerd.service && systemctl is-active --quiet containerd.service; then
    log "stopping containerd.service"
    systemctl stop containerd.service
    wait_until_inactive containerd.service || return 1
    QUIESCED=1
  fi
  return 0
}

start_stack() {
  # Start containerd first (if present)
  if svc_exists containerd.service && ! systemctl is-active --quiet containerd.service; then
    log "starting containerd.service"
    systemctl start containerd.service
    wait_until_active containerd.service || return 1
  fi
  # Then Docker
  if svc_exists docker.service && ! systemctl is-active --quiet docker.service; then
    log "starting docker.service"
    systemctl start docker.service
    wait_until_active docker.service || return 1
  fi
  # Sanity: docker CLI healthy
  if command -v docker >/dev/null 2>&1; then
    local t=60
    until docker info >/dev/null 2>&1; do
      ((t--)) || { log "docker did not become healthy in time"; return 1; }
      sleep 1
    done
  fi
  log "docker is up and healthy"
  return 0
}

# ---------- CLI parsing (CLI > config > defaults) ----------
OPT_CONF="" OPT_BACKUP_DIR="" OPT_KEEP=""
while getopts ":c:d:k:h" opt; do
  case "$opt" in
    c) OPT_CONF="$OPTARG" ;;
    d) OPT_BACKUP_DIR="$OPTARG" ;;
    k) OPT_KEEP="$OPTARG" ;;
    h) usage; exit 0 ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage; exit 2 ;;
    :)  echo "Option -$OPTARG requires an argument" >&2; usage; exit 2 ;;
  esac
done

# If a custom config file was passed, use it; otherwise keep default
if [[ -n "$OPT_CONF" ]]; then
  CONF="$OPT_CONF"
fi

# Source config file if present
if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi

# Apply CLI overrides last
if [[ -n "$OPT_BACKUP_DIR" ]]; then BACKUP_DIR="$OPT_BACKUP_DIR"; fi
if [[ -n "$OPT_KEEP" ]]; then KEEP="$OPT_KEEP"; fi

# ---------- Validate key inputs ----------
if ! [[ "$KEEP" =~ ^[0-9]+$ ]]; then
  log "KEEP must be a non-negative integer (got: $KEEP)"; exit 2
fi
if ! [[ "${REQUIRE_MOUNTPOINT}" =~ ^[01]$ ]]; then
  log "REQUIRE_MOUNTPOINT must be 0 or 1 (got: $REQUIRE_MOUNTPOINT)"; exit 2
fi

# ---------- Core vars ----------
SRC="/var/lib/docker/swarm"
HOST="$(hostname -s)"
TS="$(date +%s%z)"
ENGINE="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
ARCHIVE="${BACKUP_DIR}/swarm-${ENGINE}-${HOST}-${TS}.tgz"
LOCKDIR="${BACKUP_DIR}/.swarm-backup.lock"

# ---------- Preconditions ----------
if ! command -v docker >/dev/null 2>&1; then
  log "docker CLI not found"; exit 1
fi

# Ensure this node is a manager (not just in Swarm)
if [[ "$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || echo false)" != "true" ]]; then
  log "this node is not a swarm manager (ControlAvailable=false)"; exit 0
fi

# If leader, skip (your requested behavior)
if [[ "$(docker node inspect self --format '{{ .ManagerStatus.Leader }}' 2>/dev/null || echo false)" == "true" ]]; then
  echo "skipping backup, this is the current leader"
  exit 0
fi

# Ensure backup dir exists (and is a mount if required)
mkdir -p "$BACKUP_DIR"
if [[ "$REQUIRE_MOUNTPOINT" == "1" ]] && ! mountpoint -q "$BACKUP_DIR"; then
  log "backup dir $BACKUP_DIR is not a mountpoint; aborting"
  exit 1
fi

# ---------- Single-run lock across non-leaders (NFS-safe) ----------
cleanup() {
  local rc=$?
  # Always remove lock if we held it
  if [[ -d "$LOCKDIR" && -f "$LOCKDIR/holder" ]]; then
    # Ensure we only remove our own lock (best-effort)
    rm -rf -- "$LOCKDIR"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'log "error: command failed (rc=$?) at line $LINENO"' ERR

if mkdir "$LOCKDIR" 2>/dev/null; then
  echo "$HOST $$ $(date -Is)" > "${LOCKDIR}/holder"
  log "lock acquired by ${HOST}; backup dir=${BACKUP_DIR} keep=${KEEP}"

  # Sanity: source exists
  if [[ ! -d "$SRC" ]]; then
    log "source dir $SRC not found"; exit 1
  fi

# ---------- Quiesce, Backup, Restore ----------
log "quiescing docker/containerd for consistent snapshot"
stop_stack || { log "failed to stop services safely"; exit 1; }

# Ensure we always try to bring services back if we quiesced
restore_services() {
  if [[ "${QUIESCED:-0}" == "1" ]]; then
    log "restoring services after backup (or on error)"
    start_stack || log "WARNING: failed to restart services; manual check required"
  fi
}
trap restore_services EXIT

log "creating archive: $ARCHIVE"
tar cvzf "$ARCHIVE" "$SRC"
log "backup complete: $ARCHIVE"

# Start services now (trap is a safety net)
start_stack || { log "failed to restart services"; exit 1; }

  # ---------- Retention ----------
  if compgen -G "${BACKUP_DIR}/swarm-*.tgz" > /dev/null; then
    mapfile -t files < <(ls -1t "${BACKUP_DIR}"/swarm-*.tgz 2>/dev/null || true)
    count=${#files[@]}
    if (( count > KEEP )); then
      for f in "${files[@]:KEEP}"; do
        rm -f -- "$f" && log "pruned old backup: $f"
      done
    fi
  fi

else
  holder="$(cat "${LOCKDIR}/holder" 2>/dev/null || echo unknown)"
  log "another manager is already performing the backup (lock held by: ${holder}). exiting."
fi
