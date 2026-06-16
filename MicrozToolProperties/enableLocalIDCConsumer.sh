#!/bin/sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SH_LOG="/tmp/microz_logs/enableLocalIDCConsumer.log"
SSH_KEY_FILE="${MICROZ_SSH_KEY_FILE:-$SCRIPT_DIR/id_rsa}"
PLAYBOOK="$SCRIPT_DIR/enableLocalIDCConsumer.yml"
ANSIBLE_CFG="$SCRIPT_DIR/ansible.cfg"
REMOTE_SCRIPT="/home/sas/dad/AdventNet/Sas/tomcat/webapps/ROOT/WEB-INF/conf/enableConsumer.sh"
CONFIG_FILE="/home/sas/dad/AdventNet/Sas/tomcat/webapps/ROOT/WEB-INF/conf/configuration.properties"
REMOTE_RUN="/home/sas/dad/AdventNet/Sas/bin/remote_run.sh"
ANSIBLE_PLAYBOOK_CMD="${ANSIBLE_PLAYBOOK_BIN:-$(command -v ansible-playbook 2>/dev/null)}"
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

ANSIBLE_USER="${TARGET_HOST%%@*}"
ANSIBLE_HOST="${TARGET_HOST##*@}"
if [ -z "$ANSIBLE_HOST" ] || [ "$ANSIBLE_USER" = "$TARGET_HOST" ]; then
    log "ERROR: malformed user@host: $TARGET_HOST"
    exit 2
fi

if [ ! -f "$SSH_KEY_FILE" ]; then
    log "ERROR: ssh private key not found: $SSH_KEY_FILE"
    exit 3
fi

if [ ! -f "$PLAYBOOK" ]; then
    log "ERROR: ansible playbook not found: $PLAYBOOK"
    exit 3
fi

if [ -z "$ANSIBLE_PLAYBOOK_CMD" ] || [ ! -x "$ANSIBLE_PLAYBOOK_CMD" ]; then
    log "ERROR: ansible-playbook not found in PATH"
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

VARS_FILE="$(mktemp "${TMPDIR:-/tmp}/microz_ansible_vars.XXXXXX")"
CAPTURE_FILE="$(mktemp "${TMPDIR:-/tmp}/microz_ansible_out.XXXXXX")"
chmod 600 "$VARS_FILE" "$CAPTURE_FILE"
trap 'rm -f "$VARS_FILE" "$CAPTURE_FILE"' EXIT INT TERM

{
    printf 'ansible_user: %s\n' "$ANSIBLE_USER"
    printf 'ansible_ssh_private_key_file: %s\n' "$SSH_KEY_FILE"
    printf 'remote_cmd: |\n'
    printf '  %s\n' "$REMOTE_CMD"
} > "$VARS_FILE"

export ANSIBLE_CONFIG="$ANSIBLE_CFG"
export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_LOCAL_TEMP="/tmp/microz_ansible/tmp"
export ANSIBLE_REMOTE_TEMP="/tmp/microz_ansible/remote_tmp"

log "ansible-playbook -i ${ANSIBLE_HOST}, -e @${VARS_FILE} ${PLAYBOOK}"

if [ -n "$_TIMEOUT_BIN" ]; then
    "$_TIMEOUT_BIN" 60 \
        "$ANSIBLE_PLAYBOOK_CMD" \
            -i "${ANSIBLE_HOST}," \
            -e "@${VARS_FILE}" \
            "$PLAYBOOK" > "$CAPTURE_FILE" 2>&1
    OUTER_RC=$?
else
    "$ANSIBLE_PLAYBOOK_CMD" \
        -i "${ANSIBLE_HOST}," \
        -e "@${VARS_FILE}" \
        "$PLAYBOOK" > "$CAPTURE_FILE" 2>&1 &
    _CMD_PID=$!
    ( sleep 60; kill -TERM "$_CMD_PID" 2>/dev/null ) &
    _WATCH_PID=$!
    wait "$_CMD_PID"
    OUTER_RC=$?
    kill "$_WATCH_PID" 2>/dev/null
    wait "$_WATCH_PID" 2>/dev/null
fi

cat "$CAPTURE_FILE" >> "$SH_LOG"

if [ "$OUTER_RC" -eq 124 ] || [ "$OUTER_RC" -eq 137 ] || [ "$OUTER_RC" -eq 143 ]; then
    log "SKIP: $TARGET_HOST unreachable or timed out (exit $OUTER_RC)"
    log "ansible exit code for $TARGET_HOST : $OUTER_RC"
    log "===== SCRIPT DONE ====="
    exit 0
fi

SENTINEL_RC="$(grep -oE 'MICROZ_REMOTE_RC=[0-9]+' "$CAPTURE_FILE" | tail -1 | sed 's/MICROZ_REMOTE_RC=//')"

if [ -n "$SENTINEL_RC" ]; then
    RC=$SENTINEL_RC
elif grep -qiE 'Permission denied|publickey|Authentication failed' "$CAPTURE_FILE"; then
    RC=5
    log "ERROR: authentication failed for $TARGET_HOST"
elif grep -qi 'UNREACHABLE' "$CAPTURE_FILE" || [ "$OUTER_RC" -eq 4 ]; then
    log "SKIP: $TARGET_HOST unreachable (ansible exit $OUTER_RC)"
    log "ansible exit code for $TARGET_HOST : $OUTER_RC"
    log "===== SCRIPT DONE ====="
    exit 0
else
    RC=$OUTER_RC
fi

if [ "$RC" -eq 5 ]; then
    log "ERROR: authentication failed for $TARGET_HOST (exit 5)"
fi

if [ "$RC" -eq 255 ]; then
    log "SKIP: $TARGET_HOST unreachable or timed out (exit $RC)"
    log "ansible exit code for $TARGET_HOST : $RC"
    log "===== SCRIPT DONE ====="
    exit 0
fi

log "ansible exit code for $TARGET_HOST : $RC"
log "===== SCRIPT DONE ====="
exit $RC
