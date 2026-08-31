#!/usr/bin/env bash
# Regression tests for enableLocalIDCConsumer.sh (TOTP via MICROZ_SSH_TOTP).
#
# sshpass / ssh are stubbed on PATH; argv is recorded for assertions.
# Run:  bash tests/test_enableLocalIDCConsumer.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_DIR/MicrozToolProperties/enableLocalIDCConsumer.sh"

pass=0
fail=0
failures=()

setup_sandbox() {
    SANDBOX="$(mktemp -d)"
    BIN="$SANDBOX/bin"
    mkdir -p "$BIN"
    ARGS_FILE="$SANDBOX/cmd.log"
    : > "$ARGS_FILE"

    cat > "$BIN/sshpass" <<EOF
#!/usr/bin/env bash
echo "sshpass \$*" >> "$ARGS_FILE"
if [ "\$1" = "-P" ]; then
    echo "OTP_PROMPT=\$2" >> "$ARGS_FILE"
    shift 2
fi
if [ "\$1" = "-e" ]; then
    echo "SSHPASS=\${SSHPASS:-}" >> "$ARGS_FILE"
    shift
fi
exec "\$@"
EOF
    chmod +x "$BIN/sshpass"

    cat > "$BIN/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh \$*" >> "$ARGS_FILE"
exit \${SSH_EXIT:-0}
EOF
    chmod +x "$BIN/ssh"

    export PATH="$BIN:$PATH"
    export MICROZ_SSH_TOTP="123456"
    export SSHPASS_BIN="$BIN/sshpass"
    export SSH_BIN="$BIN/ssh"
    export TMPDIR="$SANDBOX"
}

teardown_sandbox() {
    rm -rf "$SANDBOX"
    unset SSH_EXIT MICROZ_SSH_TOTP SSHPASS_BIN SSH_BIN
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
        echo "  ok   - $label"
    else
        fail=$((fail + 1))
        failures+=("$label: expected [$expected], got [$actual]")
        echo "  FAIL - $label  expected=[$expected] actual=[$actual]"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass=$((pass + 1))
        echo "  ok   - $label"
    else
        fail=$((fail + 1))
        failures+=("$label: did not find [$needle]")
        echo "  FAIL - $label  needle=[$needle]"
    fi
}

run_case() {
    echo "-- $1"
}

# ---- 1. happy path ----------------------------------------------------------
run_case "happy path: TOTP via -e -> script exit 0, forwards user/host/markers/flag"
setup_sandbox
SSH_EXIT=0 bash "$TARGET" sas@10.0.0.5 '"my.start.marker"' '"my.end.marker"' true
rc=$?
log_contents="$(cat "$ARGS_FILE")"
assert_eq "exit 0 on success" 0 "$rc"
assert_contains "sshpass uses -P OTP prompt" "OTP_PROMPT=OTP" "$log_contents"
assert_contains "sshpass uses -e" "sshpass -P OTP -e" "$log_contents"
assert_contains "TOTP passed to sshpass" "SSHPASS=123456" "$log_contents"
assert_contains "ssh target user@host" "sas@10.0.0.5" "$log_contents"
assert_contains "uses remote enableConsumer.sh" "enableConsumer.sh" "$log_contents"
assert_contains "start marker forwarded" '"my.start.marker"' "$log_contents"
assert_contains "enable flag forwarded" "true" "$log_contents"
assert_contains "ConnectTimeout set" "ConnectTimeout=15" "$log_contents"
teardown_sandbox

# ---- 2. missing TOTP --------------------------------------------------------
run_case "missing MICROZ_SSH_TOTP -> exit 1"
setup_sandbox
unset MICROZ_SSH_TOTP
bash "$TARGET" sas@10.0.0.5 a b true
assert_eq "missing TOTP exits 1" 1 $?
teardown_sandbox

# ---- 3. remote failure propagation ------------------------------------------
run_case "remote script fails (exit 1) -> script exits 1"
setup_sandbox
SSH_EXIT=1 bash "$TARGET" sas@10.0.0.5 a b true
assert_eq "propagate remote failure" 1 $?
teardown_sandbox

run_case "remote script fails (exit 7) -> script exits 7"
setup_sandbox
SSH_EXIT=7 bash "$TARGET" sas@10.0.0.5 a b true
assert_eq "propagate arbitrary remote code" 7 $?
teardown_sandbox

# ---- summary ---------------------------------------------------------------
echo
echo "=========================================="
echo "passed: $pass    failed: $fail"
if [ $fail -gt 0 ]; then
    echo "failures:"
    for f in "${failures[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
