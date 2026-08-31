#!/bin/sh
# Enable/disable a Microz consumer on one appserver via the remote enableConsumer.sh.
# Server restart is handled on the remote side; this wrapper only runs the remote script.
#
# Auth: TOTP supplied per execution via MICROZ_SSH_TOTP (never stored on disk).

REMOTE_SCRIPT="/home/sas/dad/AdventNet/Sas/tomcat/webapps/ROOT/WEB-INF/conf/enableConsumer.sh"
SSHPASS_CMD="${SSHPASS_BIN:-/opt/homebrew/bin/sshpass}"
SSH_CMD="${SSH_BIN:-/usr/bin/ssh}"

if [ -z "${MICROZ_SSH_TOTP:-}" ]; then
    echo "ERROR: TOTP not provided (MICROZ_SSH_TOTP is required)" >&2
    exit 1
fi

if [ ! -x "$SSHPASS_CMD" ] && ! command -v "$SSHPASS_CMD" >/dev/null 2>&1; then
    echo "ERROR: sshpass not found: $SSHPASS_CMD" >&2
    exit 127
fi

OTP_PROMPT="${MICROZ_SSH_OTP_PROMPT:-OTP}"

SSHPASS="$MICROZ_SSH_TOTP" "$SSHPASS_CMD" -P "$OTP_PROMPT" -e "$SSH_CMD" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o PubkeyAuthentication=no \
    -o PreferredAuthentications=keyboard-interactive,password \
    "$1" sh "$REMOTE_SCRIPT" "$2" "$3" $4
exit $?
