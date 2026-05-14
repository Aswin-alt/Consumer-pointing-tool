#!/usr/bin/env bash
# Regression tests for enableLocalIDCConsumer.sh.
#
# We never reach a real host: sshpass / ssh / timeout are stubbed on PATH and
# record their argv to a file so each test can assert what would have been
# executed. This is what prevents the "playbook hangs / silently succeeds"
# class of bug from coming back.
#
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
    TOOL_DIR="$SANDBOX/MicrozToolProperties"
    mkdir -p "$TOOL_DIR"
    echo "secret" > "$TOOL_DIR/.ssh_pass"
    chmod 600 "$TOOL_DIR/.ssh_pass"
    ARGS_FILE="$SANDBOX/cmd.log"
    : > "$ARGS_FILE"

    # Stub sshpass: log argv, then exec the remaining "ssh ..." part so the
    # ssh stub sets the real exit code.
    cat > "$BIN/sshpass" <<EOF
#!/usr/bin/env bash
echo "sshpass \$*" >> "$ARGS_FILE"
# drop the -f <file> flag pair, then exec the rest
shift; shift
exec "\$@"
EOF
    chmod +x "$BIN/sshpass"

    # Stub ssh: log argv, exit with whatever SSH_EXIT says.
    cat > "$BIN/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh \$*" >> "$ARGS_FILE"
exit \${SSH_EXIT:-0}
EOF
    chmod +x "$BIN/ssh"

    # Stub timeout: pass through, unless TIMEOUT_FORCE is set (simulate hang kill).
    cat > "$BIN/timeout" <<EOF
#!/usr/bin/env bash
if [ -n "\${TIMEOUT_FORCE:-}" ]; then
    echo "timeout \$*" >> "$ARGS_FILE"
    exit \$TIMEOUT_FORCE
fi
shift  # drop the duration arg
exec "\$@"
EOF
    chmod +x "$BIN/timeout"

    export PATH="$BIN:$PATH"
    export MICROZ_SSH_PASS_FILE="$TOOL_DIR/.ssh_pass"
    export SSHPASS_BIN="$BIN/sshpass"
    export SSH_BIN="$BIN/ssh"
    export TIMEOUT_BIN="$BIN/timeout"
    # Send the script's own log somewhere disposable.
    export TMPDIR="$SANDBOX"
}

teardown_sandbox() {
    rm -rf "$SANDBOX"
    unset SSH_EXIT TIMEOUT_FORCE MICROZ_SSH_PASS_FILE SSHPASS_BIN SSH_BIN TIMEOUT_BIN
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
run_case "happy path: ssh exit 0 -> script exit 0, forwards user/host/markers/flag"
setup_sandbox
SSH_EXIT=0 bash "$TARGET" sas@10.0.0.5 '"my.start.marker"' '"my.end.marker"' true
rc=$?
log_contents="$(cat "$ARGS_FILE")"
assert_eq "exit 0 on success" 0 "$rc"
assert_contains "ssh target user@host" "sas@10.0.0.5" "$log_contents"
assert_contains "start marker forwarded (quotes stripped)" "'my.start.marker'" "$log_contents"
assert_contains "end marker forwarded (quotes stripped)" "'my.end.marker'" "$log_contents"
assert_contains "enable flag forwarded" "'true'" "$log_contents"
assert_contains "ConnectTimeout set" "ConnectTimeout=15" "$log_contents"
teardown_sandbox

# ---- 2. arg validation ------------------------------------------------------
run_case "missing args -> exit 2"
setup_sandbox
bash "$TARGET" sas@10.0.0.5 only-one-marker
assert_eq "exit 2 on too few args" 2 $?
teardown_sandbox

run_case "invalid enable flag -> exit 2"
setup_sandbox
bash "$TARGET" sas@10.0.0.5 a b maybe
assert_eq "exit 2 on bad flag" 2 $?
teardown_sandbox

run_case "malformed user@host -> exit 2"
setup_sandbox
bash "$TARGET" "nohostpart@" a b true
assert_eq "exit 2 when host empty" 2 $?
teardown_sandbox

# ---- 3. missing password file ----------------------------------------------
run_case "missing ssh password file -> exit 3, never reaches ssh"
setup_sandbox
rm -f "$MICROZ_SSH_PASS_FILE"
SSH_EXIT=0 bash "$TARGET" sas@10.0.0.5 a b true
rc=$?
assert_eq "exit 3 when password file absent" 3 "$rc"
assert_eq "ssh never invoked" "" "$(cat "$ARGS_FILE")"
teardown_sandbox

# ---- 4. unreachable host (ssh 255) -> skip ---------------------------------
run_case "ssh exit 255 (unreachable) -> script exits 0 (skip)"
setup_sandbox
SSH_EXIT=255 bash "$TARGET" sas@10.0.0.99 a b false
assert_eq "skip on unreachable" 0 $?
teardown_sandbox

# ---- 5. HANG REGRESSION: timeout -> skip, do not propagate failure ---------
# This is the case that motivated the rewrite. Before the sshpass version,
# the playbook could hang indefinitely. Now the wrapper must bound the run
# and surface it as a skip, not a hang.
run_case "overall timeout fires (exit 124) -> script exits 0 (skip)"
setup_sandbox
TIMEOUT_FORCE=124 bash "$TARGET" sas@10.0.0.5 a b true
assert_eq "skip on timeout" 0 $?
teardown_sandbox

run_case "SIGKILL on hung process (exit 137) -> script exits 0 (skip)"
setup_sandbox
TIMEOUT_FORCE=137 bash "$TARGET" sas@10.0.0.5 a b true
assert_eq "skip on SIGKILL" 0 $?
teardown_sandbox

# ---- 6. genuine remote failure must NOT be swallowed -----------------------
# The old playbook had ignore_errors:yes which masked real restart failures.
# The new wrapper must propagate non-transport exit codes.
run_case "remote script fails (exit 1) -> script exits 1 (not swallowed)"
setup_sandbox
SSH_EXIT=1 bash "$TARGET" sas@10.0.0.5 a b true
assert_eq "propagate remote failure" 1 $?
teardown_sandbox

run_case "remote script fails (exit 7) -> script exits 7"
setup_sandbox
SSH_EXIT=7 bash "$TARGET" sas@10.0.0.5 a b true
assert_eq "propagate arbitrary remote code" 7 $?
teardown_sandbox

# ---- 6b. bad password (exit 5) must propagate AND be labeled --------------
# sshpass exit 5 = "incorrect password". This is the failure mode the user hit
# in production; the wrapper must NOT silently skip it.
run_case "sshpass exit 5 -> script exits 5, log labels it as incorrect password"
setup_sandbox
SH_LOG_OVERRIDE="$SANDBOX/microz.log"
# Re-stub sshpass to specifically return 5.
cat > "$BIN/sshpass" <<'EOF'
#!/usr/bin/env bash
exit 5
EOF
chmod +x "$BIN/sshpass"
# Point the script's log into the sandbox by patching the script path.
SH_LOG_FILE_BEFORE=$(mktemp)
bash "$TARGET" sas@10.0.0.5 a b true
rc=$?
assert_eq "exit 5 propagated" 5 "$rc"
# The script writes to /tmp/microz_logs/enableLocalIDCConsumer.log — read the tail.
assert_contains "log labels exit 5" "incorrect password" "$(tail -20 /tmp/microz_logs/enableLocalIDCConsumer.log)"
teardown_sandbox

# ---- 6c. password-auth is forced ------------------------------------------
# Pubkey auth being attempted first can cause inconsistent results across
# hosts. Wrapper must pin auth to password so sshpass actually drives it.
run_case "ssh invocation forces password auth and disables pubkey"
setup_sandbox
SSH_EXIT=0 bash "$TARGET" sas@10.0.0.5 a b true >/dev/null
log_contents="$(cat "$ARGS_FILE")"
assert_contains "PreferredAuthentications=password" "PreferredAuthentications=password" "$log_contents"
assert_contains "PubkeyAuthentication=no" "PubkeyAuthentication=no" "$log_contents"
teardown_sandbox

# ---- 7. quoting safety ------------------------------------------------------
run_case "marker with single quote is escaped, not injected"
setup_sandbox
SSH_EXIT=0 bash "$TARGET" sas@10.0.0.5 "it's.start" 'plain.end' true
rc=$?
log_contents="$(cat "$ARGS_FILE")"
assert_eq "exit 0" 0 "$rc"
# The escape sequence '\'' is how POSIX sh wraps a single quote inside ''.
assert_contains "single quote in marker survives" "it'\\''s.start" "$log_contents"
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
