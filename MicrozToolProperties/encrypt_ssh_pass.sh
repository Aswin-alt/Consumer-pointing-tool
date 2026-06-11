#!/bin/sh
# Encrypt the SSH password for enableLocalIDCConsumer.sh.
# Requires MICROZ_VAULT_KEY in the environment.
#
# Usage:
#   export MICROZ_VAULT_KEY='your-strong-passphrase'
#   sh encrypt_ssh_pass.sh                    # reads MicrozToolProperties/.ssh_pass
#   sh encrypt_ssh_pass.sh /path/to/password  # reads a specific plaintext file
#   echo 'secret' | sh encrypt_ssh_pass.sh -  # reads from stdin

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_PLAIN="$SCRIPT_DIR/.ssh_pass"
DEFAULT_ENC="$SCRIPT_DIR/.ssh_pass.enc"

PLAIN_FILE="${1:-$DEFAULT_PLAIN}"
OUT_FILE="${MICROZ_SSH_PASS_ENC_FILE:-$DEFAULT_ENC}"

if [ -z "${MICROZ_VAULT_KEY:-}" ]; then
    echo "ERROR: MICROZ_VAULT_KEY is not set" >&2
    exit 1
fi

if [ "$PLAIN_FILE" = "-" ]; then
    TMP_IN=$(mktemp)
    trap 'rm -f "$TMP_IN"' EXIT
    cat > "$TMP_IN"
    PLAIN_FILE="$TMP_IN"
elif [ ! -f "$PLAIN_FILE" ]; then
    echo "ERROR: plaintext password file not found: $PLAIN_FILE" >&2
    exit 1
fi

openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
    -pass env:MICROZ_VAULT_KEY -in "$PLAIN_FILE" -out "$OUT_FILE"
chmod 600 "$OUT_FILE"

echo "Wrote encrypted password to: $OUT_FILE"
echo "Set MICROZ_VAULT_KEY in your Tomcat/service environment."
echo "Verify SSH works, then remove the plaintext file: rm $DEFAULT_PLAIN"
