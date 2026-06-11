#!/bin/sh
# Enable/disable a Microz consumer on one appserver via the remote enableConsumer.sh.
# Server restart is handled on the remote side; this wrapper only runs the remote script.

SSH_PASS_FILE="${MICROZ_SSH_PASS_FILE:-/Users/aswin-20182/Documents/Consumer pointing tool/MicrozToolProperties/.ssh_pass}"
SSH_PASS_ENC_FILE="${MICROZ_SSH_PASS_ENC_FILE:-${SSH_PASS_FILE}.enc}"
REMOTE_SCRIPT="/home/sas/dad/AdventNet/Sas/tomcat/webapps/ROOT/WEB-INF/conf/enableConsumer.sh"
SSHPASS_CMD="${SSHPASS_BIN:-/opt/homebrew/bin/sshpass}"
SSH_CMD="${SSH_BIN:-/usr/bin/ssh}"

PASS_FILE="$SSH_PASS_FILE"
TMP=""
if [ -f "$SSH_PASS_ENC_FILE" ]; then
    TMP=$(mktemp)
    chmod 600 "$TMP"
    openssl enc -d -aes-256-cbc -salt -pbkdf2 -iter 100000 \
        -pass env:MICROZ_VAULT_KEY -in "$SSH_PASS_ENC_FILE" -out "$TMP"
    PASS_FILE="$TMP"
fi

"$SSHPASS_CMD" -f "$PASS_FILE" "$SSH_CMD" -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
    "$1" sh "$REMOTE_SCRIPT" "$2" "$3" $4
RC=$?

[ -n "$TMP" ] && rm -f "$TMP"
exit $RC
