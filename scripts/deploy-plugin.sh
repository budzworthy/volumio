#!/usr/bin/env bash
# deploy-plugin.sh — Deploy or install a plugin directory to a Volumio device.
#
# Usage:
#   ./scripts/deploy-plugin.sh <host> [plugin_name] [options]
#
# Arguments:
#   host                Device IP address or hostname (e.g. volumio.local or 192.168.1.50)
#   plugin_name         Optional plugin folder name under plugins/
#
# Options:
#   -u, --user USER     SSH user (default: volumio)
#   -p, --port PORT     SSH port (default: 22)
#   -r, --restart       Restart volumio service after deploy / install
#   -n, --dry-run       Show what would be transferred without making any changes
#   -i, --install       Install mode: copy to remote temp dir and run "volumio plugin install"
#   -h, --help          Show this help message

set -euo pipefail

# ---------- defaults ----------
SSH_USER="volumio"
SSH_PORT="22"
DRY_RUN=false
INSTALL_MODE=false
REMOTE_PLUGINS_DIR="/data/plugins"

# ---------- colours ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[deploy-plugin]${NC} $*"; }
warn()    { echo -e "${YELLOW}[deploy-plugin]${NC} $*"; }
error()   { echo -e "${RED}[deploy-plugin]${NC} $*" >&2; }

# ---------- help ----------
usage() {
  sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# ---------- argument parsing ----------
if [[ $# -eq 0 ]]; then
  error "Missing required argument: host"
  usage
fi

HOST=""
PLUGIN_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user)    SSH_USER="$2";  shift 2 ;;
    -p|--port)    SSH_PORT="$2";  shift 2 ;;
    -n|--dry-run) DRY_RUN=true; shift ;;
    -i|--install) INSTALL_MODE=true; shift ;;
    -h|--help)    usage ;;
    -*)           error "Unknown option: $1"; usage ;;
    *)
      if [[ -z "$HOST" ]]; then
        HOST="$1"; shift
      elif [[ -z "$PLUGIN_NAME" ]]; then
        PLUGIN_NAME="$1"; shift
      else
        error "Unexpected argument: $1"
        usage
      fi
      ;;
  esac
done

if [[ -z "$HOST" ]]; then
  error "Missing required argument: host"
  usage
fi

# ---------- resolve paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGINS_ROOT="$PROJECT_ROOT/plugins"

if [[ ! -d "$PLUGINS_ROOT" ]]; then
  error "Plugins directory not found: $PLUGINS_ROOT"
  exit 1
fi

if [[ -z "$PLUGIN_NAME" ]]; then
  CURRENT_DIR="$(pwd -P)"
  PARENT_DIR="$(dirname "$CURRENT_DIR")"
  if [[ "$PARENT_DIR" == "$PLUGINS_ROOT" ]]; then
    PLUGIN_NAME="$(basename "$CURRENT_DIR")"
    info "Using current folder as plugin name: $PLUGIN_NAME"
  else
    error "plugin_name not provided and current directory is not a first-level plugins folder."
    error "Run from '$PLUGINS_ROOT/<plugin>' or provide plugin_name explicitly."
    exit 1
  fi
fi

if [[ "$PLUGIN_NAME" == *"/"* ]]; then
  error "plugin_name must be a first-level folder name under plugins/, not a path."
  exit 1
fi

PLUGIN_DIR="$PLUGINS_ROOT/$PLUGIN_NAME"
if [[ ! -d "$PLUGIN_DIR" ]]; then
  error "Plugin directory not found: $PLUGIN_DIR"
  exit 1
fi

# ---------- detect plugin_type from package.json ----------
PLUGIN_TYPE=""
PACKAGE_JSON="$PLUGIN_DIR/package.json"
if [[ -f "$PACKAGE_JSON" ]]; then
  if command -v node >/dev/null 2>&1; then
    PLUGIN_TYPE=$(node -e "try{const p=require('path').resolve(process.argv[1]);const j=JSON.parse(require('fs').readFileSync(p,'utf8'));console.log((j.volumio_info&&j.volumio_info.plugin_type)||'');}catch(e){console.log('')}" "$PACKAGE_JSON")
  elif command -v python3 >/dev/null 2>&1; then
    PLUGIN_TYPE=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('volumio_info',{}).get('plugin_type',''))" "$PACKAGE_JSON")
  else
    PLUGIN_TYPE=$(grep -Po '"plugin_type"\s*:\s*"\K[^"]+' "$PACKAGE_JSON" || true)
  fi
  if [[ -n "$PLUGIN_TYPE" ]]; then
    info "Detected plugin_type: $PLUGIN_TYPE"
  else
    info "No plugin_type detected in $PACKAGE_JSON; using default plugins directory"
  fi
fi

TARGET="${SSH_USER}@${HOST}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -p "$SSH_PORT")

if $DRY_RUN; then
  warn "Dry-run mode — no files will be transferred."
  if $INSTALL_MODE; then
    warn "Would copy '$PLUGIN_DIR' to a remote temp directory and run: volumio plugin install"
  else
    if [[ -n "$PLUGIN_TYPE" ]]; then
      warn "Would copy entire plugin directory to: ${TARGET}:${REMOTE_PLUGINS_DIR}/${PLUGIN_TYPE}/${PLUGIN_NAME}"
    else
      warn "Would copy entire plugin directory to: ${TARGET}:${REMOTE_PLUGINS_DIR}/${PLUGIN_NAME}"
    fi
  fi
  exit 0
fi

if $INSTALL_MODE; then
  REMOTE_TMP_BASE="/tmp/deploy-plugin-${PLUGIN_NAME}-$(date +%s)-$$"

  info "Creating remote temp directory: $REMOTE_TMP_BASE"
  ssh "${SSH_OPTS[@]}" "$TARGET" "mkdir -p '$REMOTE_TMP_BASE'"

  info "Copying plugin directory to remote temp directory"
  scp -P "$SSH_PORT" -o StrictHostKeyChecking=accept-new -r \
    "$PLUGIN_DIR" "$TARGET:$REMOTE_TMP_BASE/"

  info "Installing plugin on device"
  ssh "${SSH_OPTS[@]}" "$TARGET" "set -e; cd '$REMOTE_TMP_BASE/$PLUGIN_NAME'; volumio plugin install"

  info "Cleaning up remote temp directory"
  ssh "${SSH_OPTS[@]}" "$TARGET" "rm -rf '$REMOTE_TMP_BASE'"
else
  if [[ -n "$PLUGIN_TYPE" ]]; then
    REMOTE_DEST_DIR="$REMOTE_PLUGINS_DIR/$PLUGIN_TYPE"
  else
    REMOTE_DEST_DIR="$REMOTE_PLUGINS_DIR"
  fi

  info "Ensuring remote plugins directory exists: $REMOTE_DEST_DIR"
  ssh "${SSH_OPTS[@]}" "$TARGET" "mkdir -p '$REMOTE_DEST_DIR'"

  info "Copying plugin directory to ${REMOTE_DEST_DIR}/${PLUGIN_NAME}"
  scp -P "$SSH_PORT" -o StrictHostKeyChecking=accept-new -r \
    "$PLUGIN_DIR" "$TARGET:$REMOTE_DEST_DIR/"
fi

warn "Restarting volumio service."
ssh "${SSH_OPTS[@]}" "$TARGET" "sudo systemctl restart volumio"
info "Service restarted."

info "Done."
