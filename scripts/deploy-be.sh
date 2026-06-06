#!/usr/bin/env bash
# deploy-be.sh — Deploy uncommitted git changes for backend submodule to /volumio on a Volumio device.
#
# Usage:
#   ./scripts/deploy-be.sh <host> [options]
#
# Arguments:
#   host              Device IP address or hostname (e.g. volumio.local or 192.168.1.50)
#
# Options:
#   -u, --user USER   SSH user (default: volumio)
#   -p, --port PORT   SSH port (default: 22)
#   -r, --restart     Force a service restart even if no .ejs files changed
#   -n, --dry-run     Show what would be transferred without making any changes
#   -h, --help        Show this help message

set -euo pipefail

# ---------- defaults ----------
SSH_USER="volumio"
SSH_PORT="22"
FORCE_RESTART=false
DRY_RUN=false
REMOTE_DIR="/volumio"

# ---------- colours ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[deploy]${NC} $*"; }
warn()    { echo -e "${YELLOW}[deploy]${NC} $*"; }
error()   { echo -e "${RED}[deploy]${NC} $*" >&2; }

# ---------- help ----------
usage() {
  sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# ---------- argument parsing ----------
if [[ $# -eq 0 ]]; then
  error "Missing required argument: host"
  usage
fi

HOST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user)    SSH_USER="$2";  shift 2 ;;
    -p|--port)    SSH_PORT="$2";  shift 2 ;;
    -r|--restart) FORCE_RESTART=true; shift ;;
    -n|--dry-run) DRY_RUN=true;   shift ;;
    -h|--help)    usage ;;
    -*)           error "Unknown option: $1"; usage ;;
    *)
      if [[ -z "$HOST" ]]; then
        HOST="$1"; shift
      else
        error "Unexpected argument: $1"; usage
      fi
      ;;
  esac
done

if [[ -z "$HOST" ]]; then
  error "Missing required argument: host"
  usage
fi

# ---------- resolve root of BE submodule ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BE_ROOT="$(cd "$SCRIPT_DIR/../backend" && pwd)"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -p "$SSH_PORT")

# ---------- collect uncommitted files ----------
cd "$BE_ROOT"

# Staged + unstaged modifications and new (untracked) files; excludes deletions
mapfile -t CHANGED_FILES < <(
  git status --porcelain | awk '
    # skip deleted files (D in col 1 or col 2)
    /^[ MARC][D]/ { next }
    /^[D][ ?]/ { next }
    # skip directory entries (untracked dirs reported as "path/")
    /\/$/ { next }
    # everything else (untracked, modified, staged, renamed, copied)
    { print substr($0, 4) }
  '
)

if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
  info "No uncommitted changes found — nothing to deploy."
  exit 0
fi

info "Found ${#CHANGED_FILES[@]} changed file(s):"
printf '  %s\n' "${CHANGED_FILES[@]}"

if $DRY_RUN; then
  warn "Dry-run mode — no files will be transferred."
  # Check for .ejs in the list for informational purposes
  if printf '%s\n' "${CHANGED_FILES[@]}" | grep -qE '\.ejs$'; then
    warn "Would restart volumio service on device (.ejs files changed)."
  fi
  exit 0
fi

TARGET="${SSH_USER}@${HOST}"

# ---------- deploy files ----------
EJS_CHANGED=false
for FILE in "${CHANGED_FILES[@]}"; do
  DEST_DIR="${REMOTE_DIR}/$(dirname "$FILE")"
  info "Copying ${FILE}"
  ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$TARGET" "mkdir -p '${DEST_DIR}'"
  scp -P "$SSH_PORT" -o StrictHostKeyChecking=accept-new \
    "${BE_ROOT}/${FILE}" "${TARGET}:${REMOTE_DIR}/${FILE}"
  if [[ "$FILE" == *.ejs ]]; then
    EJS_CHANGED=true
  fi
done

if $EJS_CHANGED; then
  warn ".ejs files changed — restarting volumio service (NODE_ENV=production caches views)."
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "sudo systemctl restart volumio"
  info "Service restarted."
elif $FORCE_RESTART; then
  warn "--restart flag set — restarting volumio service."
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "sudo systemctl restart volumio"
  info "Service restarted."
else
  info "No .ejs files changed — service restart not required."
fi

info "Done."
