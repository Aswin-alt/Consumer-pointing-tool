#!/bin/sh

SH_LOG="/tmp/microz_logs/enableLocalIDCConsumer.log"
SSH_PASS_FILE="${MICROZ_SSH_PASS_FILE:-/Users/aswin-20182/Documents/Consumer pointing tool/MicrozToolProperties/.ssh_pass}"
REMOTE_SCRIPT="/home/sas/dad/AdventNet/Sas/tomcat/webapps/ROOT/WEB-INF/conf/enableConsumer.sh"
CONFIG_FILE="/home/sas/dad/AdventNet/Sas/tomcat/webapps/ROOT/WEB-INF/conf/configuration.properties"
REMOTE_RUN="/home/sas/dad/AdventNet/Sas/bin/remote_run.sh"

SSHPASS_CMD="${SSHPASS_BIN:-/opt/homebrew/bin/sshpass}"
SSH_CMD="${SSH_BIN:-/usr/bin/ssh}"
_TIMEOUT_BIN="${TIMEOUT_BIN:-$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null)}"

mkdir -p "$(dirname "$SH_LOG")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$SH_LOG"
}

log "===== SCRIPT INVOKED ====="
log "ARG1 (target host) : ${1:-}"
log "ARG2 (startMarker) : ${2:-}"
log "ARG3 (endMarker)   : ${3:-}"
log "ARG4 (enable flag) : ${4:-}"

if [ $# -lt 4 ]; then
    log "ERROR: requires 4 arguments, got $#"
    exit 2
fi

TARGET_HOST="$1"
START_MARKER="$2"
END_MARKER="$3"
ENABLE_FLAG="$4"

if [ "$ENABLE_FLAG" != "true" ] && [ "$ENABLE_FLAG" != "false" ]; then
    log "ERROR: invalid enable flag: $ENABLE_FLAG"
    exit 2
fi

HOST_PART="${TARGET_HOST##*@}"
if [ -z "$HOST_PART" ]; then
    log "ERROR: malformed user@host: $TARGET_HOST"
    exit 2
fi

if [ ! -f "$SSH_PASS_FILE" ]; then
    log "ERROR: ssh password file not found: $SSH_PASS_FILE"
    exit 3
fi

strip_outer_dquotes() {
    _v="$1"
    case "$_v" in
        \"*\") _v="${_v#\"}"; _v="${_v%\"}" ;;
    esac
    printf '%s' "$_v"
}

START_MARKER=$(strip_outer_dquotes "$START_MARKER")
END_MARKER=$(strip_outer_dquotes "$END_MARKER")
ENABLE_FLAG=$(strip_outer_dquotes "$ENABLE_FLAG")

sq() {
    _v="$1"
    _v=$(printf '%s' "$_v" | sed "s/'/'\\\\''/g")
    printf "'%s'" "$_v"
}

Q_START=$(sq "$START_MARKER")
Q_END=$(sq "$END_MARKER")
Q_FLAG=$(sq "$ENABLE_FLAG")

# Use existing remote enableConsumer.sh only (no deploy / no stdin script).
# If configuration changed, re-run remote_run.sh under nohup so restart survives SSH disconnect.
REMOTE_CMD="cd /home/sas && \
OLD=\$(grep -m1 '^${START_MARKER}=' '${CONFIG_FILE}' 2>/dev/null | cut -d= -f2-) && \
sh '${REMOTE_SCRIPT}' ${Q_START} ${Q_END} ${Q_FLAG}; EC=\$?; \
NEW=\$(grep -m1 '^${START_MARKER}=' '${CONFIG_FILE}' 2>/dev/null | cut -d= -f2-); \
if [ \"\$OLD\" != \"\$NEW\" ]; then nohup sh '${REMOTE_RUN}' </dev/null >/dev/null 2>&1 & fi; \
exit \$EC"

if [ -n "$_TIMEOUT_BIN" ]; then
    "$_TIMEOUT_BIN" 60 \
        "$SSHPASS_CMD" -f "$SSH_PASS_FILE" \
        "$SSH_CMD" \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=15 \
            -o PreferredAuthentications=password \
            -o PubkeyAuthentication=no \
            "$TARGET_HOST" \
            "$REMOTE_CMD" >> "$SH_LOG" 2>&1
    RC=$?
else
    "$SSHPASS_CMD" -f "$SSH_PASS_FILE" \
        "$SSH_CMD" \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=15 \
            -o PreferredAuthentications=password \
            -o PubkeyAuthentication=no \
            "$TARGET_HOST" \
            "$REMOTE_CMD" >> "$SH_LOG" 2>&1 &
    _CMD_PID=$!
    ( sleep 60; kill -TERM "$_CMD_PID" 2>/dev/null ) &
    _WATCH_PID=$!
    wait "$_CMD_PID"
    RC=$?
    kill "$_WATCH_PID" 2>/dev/null
    wait "$_WATCH_PID" 2>/dev/null
fi

if [ "$RC" -eq 5 ]; then
    log "ERROR: incorrect password for $TARGET_HOST (sshpass exit 5)"
fi

if [ "$RC" -eq 255 ] || [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ] || [ "$RC" -eq 143 ]; then
    log "SKIP: $TARGET_HOST unreachable or timed out (exit $RC)"
    log "ssh exit code for $TARGET_HOST : $RC"
    log "===== SCRIPT DONE ====="
    exit 0
fi

log "ssh exit code for $TARGET_HOST : $RC"
log "===== SCRIPT DONE ====="
exit $RC
