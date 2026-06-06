#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 <host>"
    echo "       $0 --host <host>"
    exit 1
}

HOST=""
PASSWORD=""

if [[ $# -eq 1 && "$1" != --* ]]; then
    HOST="$1"
elif [[ $# -gt 0 ]]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)     HOST="$2";     shift 2 ;;
            *) usage ;;
        esac
    done
fi

[[ -z "$HOST" ]] && usage

read -r -s -p "New password for volumio@${HOST}: " PASSWORD
echo
read -r -s -p "Confirm password: " PASSWORD_CONFIRM
echo

if [[ "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
    echo "Error: passwords do not match."
    exit 1
fi

[[ -z "$PASSWORD" ]] && { echo "Error: password cannot be empty."; exit 1; }

DEFAULT_USER="volumio"
DEFAULT_PASS="volumio"

# Discover keys loaded in the SSH agent
mapfile -t AGENT_KEYS < <(ssh-add -L 2>/dev/null)

if [[ ${#AGENT_KEYS[@]} -eq 0 ]]; then
    echo "Error: no keys found in SSH agent. Add a key with: ssh-add ~/.ssh/id_ed25519"
    exit 1
fi

echo "Available SSH keys:"
for i in "${!AGENT_KEYS[@]}"; do
    # The comment (typically the key name/path) is the last field
    KEY_NAME="${AGENT_KEYS[$i]##* }"
    printf "  [%d] %s\n" "$((i + 1))" "$KEY_NAME"
done

while true; do
    read -r -p "Select key [1-${#AGENT_KEYS[@]}]: " KEY_CHOICE
    if [[ "$KEY_CHOICE" =~ ^[0-9]+$ ]] && (( KEY_CHOICE >= 1 && KEY_CHOICE <= ${#AGENT_KEYS[@]} )); then
        break
    fi
    echo "Invalid selection."
done

SSH_PUBKEY="${AGENT_KEYS[$((KEY_CHOICE - 1))]}"

if ! command -v sshpass &>/dev/null; then
    echo "Error: sshpass is required. Install it with: sudo apt-get install sshpass"
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

echo "Connecting to ${DEFAULT_USER}@${HOST}..."

# Pass password and pubkey as positional args to the remote script so that
# special characters in the password are handled safely (<<'ENDSSH' is unquoted
# locally, so $1/$2 are never interpreted by the local shell).
sshpass -p "$DEFAULT_PASS" ssh $SSH_OPTS "${DEFAULT_USER}@${HOST}" bash -s -- "$PASSWORD" "$SSH_PUBKEY" << 'ENDSSH'
set -e
NEW_PASS="$1"
PUBKEY="$2"
USERNAME=$(whoami)

# Change password
printf '%s:%s\n' "$USERNAME" "$NEW_PASS" | sudo chpasswd
echo "Password changed."

# Add SSH public key to authorized_keys (skip if already present)
mkdir -p ~/.ssh
chmod 700 ~/.ssh
if ! grep -qF "$PUBKEY" ~/.ssh/authorized_keys 2>/dev/null; then
    printf '%s\n' "$PUBKEY" >> ~/.ssh/authorized_keys
    echo "SSH public key added."
else
    echo "SSH public key already present."
fi
chmod 600 ~/.ssh/authorized_keys
ENDSSH

echo "Done. Device ${HOST} is ready."
