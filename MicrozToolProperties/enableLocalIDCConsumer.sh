#!/bin/sh

SH_LOG="/tmp/microz_logs/enableLocalIDCConsumer.log"
SSH_PASS_FILE="/Users/aswin-20182/Documents/Consumer pointing tool/MicrozToolProperties/.ssh_pass"
REMOTE_SCRIPT="/home/sas/dad/AdventNet/Sas/tomcat/webapps/ROOT/WEB-INF/conf/enableConsumer.sh"

mkdir -p "$(dirname "$SH_LOG")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$SH_LOG"
}

log "===== SCRIPT INVOKED ====="
log "ARG1 (target host) : $1"
log "ARG2 (startMarker) : $2"
log "ARG3 (endMarker)   : $3"
log "ARG4 (enable flag) : $4"

/opt/homebrew/bin/sshpass -f "$SSH_PASS_FILE" /usr/bin/ssh -o StrictHostKeyChecking=no "$1" \
    sh "$REMOTE_SCRIPT" "$2" "$3" "$4" >> "$SH_LOG" 2>&1
RC=$?

log "ssh exit code for $1 : $RC"
log "===== SCRIPT DONE ====="
exit $RC
