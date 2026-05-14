#!/bin/sh

SH_LOG="/tmp/microz_logs/enableLocalIDCConsumer.log"
TOOL_DIR="/Users/aswin-20182/Documents/Consumer pointing tool/MicrozToolProperties"
SSH_PASS_FILE="${MICROZ_SSH_PASS_FILE:-$TOOL_DIR/.ssh_pass}"
REMOTE_SCRIPT="/home/sas/dad/AdventNet/Sas/tomcat/webapps/ROOT/WEB-INF/conf/enableConsumer.sh"

# Hard caps so a wedged remote can never hang the servlet thread.
CONNECT_TIMEOUT="${MICROZ_CONNECT_TIMEOUT:-15}"
OVERALL_TIMEOUT="${MICROZ_OVERALL_TIMEOUT:-120}"

SSHPASS_BIN="${SSHPASS_BIN:-/opt/homebrew/bin/sshpass}"
SSH_BIN="${SSH_BIN:-ssh}"
TIMEOUT_BIN="${TIMEOUT_BIN:-/opt/homebrew/bin/gtimeout}"
if [ ! -x "$TIMEOUT_BIN" ]; then
    TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)"
fi

mkdir -p "$(dirname "$SH_LOG")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$SH_LOG"
}

log "===== SCRIPT INVOKED ====="
log "PID=$$  PPID=$PPID"
log "ARG1 (target host) : $1"
log "ARG2 (startMarker) : $2"
log "ARG3 (endMarker)   : $3"
log "ARG4 (enable flag) : $4"
log "Running as user    : $(whoami)"

if [ $# -lt 4 ]; then
    log "ERROR: expected 4 args (user@host startMarker endMarker enableFlag), got $#"
    exit 2
fi

REMOTE_USER=$(echo "$1" | cut -d'@' -f1)
REMOTE_HOST=$(echo "$1" | cut -d'@' -f2)
START_MARKER=$(echo "$2" | tr -d '"')
END_MARKER=$(echo "$3" | tr -d '"')
ENABLE_FLAG="$4"

if [ -z "$REMOTE_USER" ] || [ -z "$REMOTE_HOST" ]; then
    log "ERROR: could not parse user@host from '$1'"
    exit 2
fi

case "$ENABLE_FLAG" in
    true|false) ;;
    *) log "ERROR: enable flag must be 'true' or 'false', got '$ENABLE_FLAG'"; exit 2 ;;
esac

if [ ! -r "$SSH_PASS_FILE" ]; then
    log "ERROR: SSH password file not readable: $SSH_PASS_FILE"
    exit 3
fi

if [ ! -x "$SSHPASS_BIN" ] && ! command -v "$SSHPASS_BIN" >/dev/null 2>&1; then
    log "ERROR: sshpass not found at $SSHPASS_BIN"
    exit 3
fi

PASS_HASH=$(md5 -q "$SSH_PASS_FILE" 2>/dev/null || md5sum "$SSH_PASS_FILE" 2>/dev/null | awk '{print $1}')
PASS_BYTES=$(wc -c < "$SSH_PASS_FILE" | tr -d ' ')
log "Connecting to $REMOTE_HOST as $REMOTE_USER (connect_timeout=${CONNECT_TIMEOUT}s overall_timeout=${OVERALL_TIMEOUT}s)"
log "ssh_pass file=$SSH_PASS_FILE bytes=$PASS_BYTES md5=$PASS_HASH"
log "start_marker=$START_MARKER  end_marker=$END_MARKER  consumer_enable=$ENABLE_FLAG"

# Single-quote each remote arg so spaces/dots/special chars survive the shell on the remote side.
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
REMOTE_CMD="sh $(quote "$REMOTE_SCRIPT") $(quote "$START_MARKER") $(quote "$END_MARKER") $(quote "$ENABLE_FLAG")"
log "remote_cmd=$REMOTE_CMD"
T_START=$(date +%s)

RUN_PREFIX=""
if [ -n "$TIMEOUT_BIN" ]; then
    RUN_PREFIX="$TIMEOUT_BIN $OVERALL_TIMEOUT"
else
    log "WARN: no timeout binary available; falling back to ssh-level timeouts only"
fi

# shellcheck disable=SC2086
$RUN_PREFIX "$SSHPASS_BIN" -f "$SSH_PASS_FILE" \
    "$SSH_BIN" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout="$CONNECT_TIMEOUT" \
        -o ServerAliveInterval=10 \
        -o ServerAliveCountMax=3 \
        -o BatchMode=no \
        -o ProxyCommand=none \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        "$REMOTE_USER@$REMOTE_HOST" "$REMOTE_CMD" >> "$SH_LOG" 2>&1
RC=$?
T_END=$(date +%s)
ELAPSED=$((T_END - T_START))

case "$RC" in
    0)   RC_LABEL="ok" ;;
    1)   RC_LABEL="remote-script-error" ;;
    5)   RC_LABEL="sshpass: incorrect password" ;;
    6)   RC_LABEL="sshpass: host public key unknown" ;;
    124) RC_LABEL="overall timeout (${OVERALL_TIMEOUT}s) — process killed" ;;
    137) RC_LABEL="overall timeout — SIGKILL" ;;
    255) RC_LABEL="ssh transport: unreachable / auth / network" ;;
    *)   RC_LABEL="see remote stdout/stderr above" ;;
esac
log "ssh exit code for $REMOTE_HOST : $RC ($RC_LABEL) elapsed=${ELAPSED}s"

# 124 = GNU timeout killed the process (hang). Treat as skip so one bad host
# doesn't fail the whole batch, but log loudly.
if [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ]; then
    log "Host $REMOTE_HOST timed out after ${OVERALL_TIMEOUT}s — skipping"
    log "===== SCRIPT DONE (TIMEOUT) ====="
    exit 0
fi

# 255 = ssh transport failure (unreachable / network) — treat as skip so one
# dead host doesn't block the whole batch.
if [ "$RC" -eq 255 ]; then
    log "Host $REMOTE_HOST unreachable or ssh failure — skipping"
    log "===== SCRIPT DONE (SKIPPED) ====="
    exit 0
fi

log "===== SCRIPT DONE ====="
exit $RC
