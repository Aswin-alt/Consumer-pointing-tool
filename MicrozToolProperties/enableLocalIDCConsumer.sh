#!/bin/sh

SH_LOG="/tmp/microz_logs/enableLocalIDCConsumer.log"
TOOL_DIR="/Users/aswin-20182/Documents/Consumer pointing tool/MicrozToolProperties"
PLAYBOOK="$TOOL_DIR/enableConsumer.yml"
VAULT_PASS_FILE="$TOOL_DIR/.vault_pass"

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

echo $2
echo $3
echo $4

# Parse user@host from $1
REMOTE_USER=$(echo "$1" | cut -d'@' -f1)
REMOTE_HOST=$(echo "$1" | cut -d'@' -f2)

# Strip the literal surrounding quotes that the properties file includes
# e.g. "microz.consumer.enable.Foo" -> microz.consumer.enable.Foo
START_MARKER=$(echo "$2" | tr -d '"')
END_MARKER=$(echo "$3" | tr -d '"')

log "Invoking ansible-playbook on $REMOTE_HOST as $REMOTE_USER ..."
log "start_marker=$START_MARKER  end_marker=$END_MARKER  consumer_enable=$4"

/opt/homebrew/bin/ansible-playbook \
    -i "$REMOTE_HOST," \
    -u "$REMOTE_USER" \
    --ssh-extra-args="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ProxyCommand=none" \
    --vault-password-file "$VAULT_PASS_FILE" \
    --extra-vars "{\"start_marker\": \"$START_MARKER\", \"end_marker\": \"$END_MARKER\", \"consumer_enable\": \"$4\"}" \
    "$PLAYBOOK" >> "$SH_LOG" 2>&1

ANSIBLE_EXIT=$?
log "ansible-playbook exit code for $REMOTE_HOST : $ANSIBLE_EXIT"

# Exit code 4 = unreachable host — treat as skip, not failure
if [ "$ANSIBLE_EXIT" -eq 4 ]; then
    log "Host $REMOTE_HOST is unreachable — skipping"
    log "===== SCRIPT DONE (SKIPPED) ====="
    exit 0
fi

log "===== SCRIPT DONE ====="
exit $ANSIBLE_EXIT
