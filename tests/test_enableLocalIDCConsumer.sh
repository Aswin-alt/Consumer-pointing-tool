#!/usr/bin/env bash
# Regression tests for enableLocalIDCConsumer.sh.
#
# We never reach a real host: ansible-playbook / timeout are stubbed on PATH and
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
    echo "dummy-key" > "$TOOL_DIR/id_rsa"
    chmod 600 "$TOOL_DIR/id_rsa"
    cp "$REPO_DIR/MicrozToolProperties/enableLocalIDCConsumer.yml" "$TOOL_DIR/"
    cp "$REPO_DIR/MicrozToolProperties/ansible.cfg" "$TOOL_DIR/"
    ARGS_FILE="$SANDBOX/cmd.log"
    : > "$ARGS_FILE"

    # Stub ansible-playbook: log argv + vars file contents, simulate outcomes.
    cat > "$BIN/ansible-playbook" <<EOF
#!/usr/bin/env bash
echo "ansible-playbook \$*" >> "$ARGS_FILE"
varsfile=""
prev=""
for arg in "\$@"; do
    if [ "\$prev" = "-e" ]; then
        case "\$arg" in
            @*) varsfile="\${arg#@}" ;;
        esac
        prev=""
        continue
    fi
    prev="\$arg"
done
if [ -n "\$varsfile" ] && [ -f "\$varsfile" ]; then
    cat "\$varsfile" >> "$ARGS_FILE"
fi
if [ -n "\${AUTH_FAIL:-}" ]; then
    echo "Permission denied (publickey)."
    exit 4
fi
if [ -n "\${UNREACHABLE:-}" ]; then
    echo "UNREACHABLE!"
    exit 4
fi
echo "MICROZ_REMOTE_RC=\${REMOTE_RC:-0}"
exit 0
EOF
    chmod +x "$BIN/ansible-playbook"

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
    export MICROZ_SSH_KEY_FILE="$TOOL_DIR/id_rsa"
    export ANSIBLE_PLAYBOOK_BIN="$BIN/ansible-playbook"
    export TIMEOUT_BIN="$BIN/timeout"
    export TMPDIR="$SANDBOX"
}

teardown_sandbox() {
    rm -rf "$SANDBOX"
    unset REMOTE_RC AUTH_FAIL UNREACHABLE TIMEOUT_FORCE MICROZ_SSH_KEY_FILE ANSIBLE_PLAYBOOK_BIN TIMEOUT_BIN
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
run_case "happy path: remote rc 0 -> script exit 0, forwards host/markers/flag"
setup_sandbox
REMOTE_RC=0 bash "$TARGET" sas@10.0.0.5 '"my.start.marker"' '"my.end.marker"' true
rc=$?
log_contents="$(cat "$ARGS_FILE")"
assert_eq "exit 0 on success" 0 "$rc"
assert_contains "inventory host" "10.0.0.5," "$log_contents"
assert_contains "uses remote enableConsumer.sh" "enableConsumer.sh" "$log_contents"
assert_contains "start marker forwarded" "'my.start.marker'" "$log_contents"
assert_contains "enable flag forwarded" "'true'" "$log_contents"
assert_contains "nohup restart when config changes" "nohup sh" "$log_contents"
assert_contains "ansible user set" "ansible_user: sas" "$log_contents"
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

# ---- 3. missing key file ----------------------------------------------------
run_case "missing ssh private key -> exit 3, never reaches ansible"
setup_sandbox
rm -f "$MICROZ_SSH_KEY_FILE"
REMOTE_RC=0 bash "$TARGET" sas@10.0.0.5 a b true
rc=$?
assert_eq "exit 3 when key file absent" 3 "$rc"
assert_eq "ansible never invoked" "" "$(cat "$ARGS_FILE")"
teardown_sandbox

# ---- 4. unreachable host -> skip --------------------------------------------
run_case "unreachable host -> script exits 0 (skip)"
setup_sandbox
UNREACHABLE=1 bash "$TARGET" sas@10.0.0.99 a b false
assert_eq "skip on unreachable" 0 $?
teardown_sandbox

# ---- 5. HANG REGRESSION: timeout -> skip, do not propagate failure ---------
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
run_case "remote script fails (exit 1) -> script exits 1 (not swallowed)"
setup_sandbox
REMOTE_RC=1 bash "$TARGET" sas@10.0.0.5 a b true
assert_eq "propagate remote failure" 1 $?
teardown_sandbox

run_case "remote script fails (exit 7) -> script exits 7"
setup_sandbox
REMOTE_RC=7 bash "$TARGET" sas@10.0.0.5 a b true
assert_eq "propagate arbitrary remote code" 7 $?
teardown_sandbox

# ---- 6b. auth failure must propagate AND be labeled ------------------------
run_case "auth failure -> script exits 5, log labels authentication failed"
setup_sandbox
AUTH_FAIL=1 bash "$TARGET" sas@10.0.0.5 a b true
rc=$?
assert_eq "exit 5 propagated" 5 "$rc"
assert_contains "log labels exit 5" "authentication failed" "$(tail -20 /tmp/microz_logs/enableLocalIDCConsumer.log)"
teardown_sandbox

# ---- 6c. private key is passed to ansible ----------------------------------
run_case "ansible vars include private key file path"
setup_sandbox
REMOTE_RC=0 bash "$TARGET" sas@10.0.0.5 a b true >/dev/null
log_contents="$(cat "$ARGS_FILE")"
assert_contains "ansible_ssh_private_key_file set" "ansible_ssh_private_key_file:" "$log_contents"
teardown_sandbox

# ---- 7. quoting safety ------------------------------------------------------
run_case "marker with single quote is escaped, not injected"
setup_sandbox
REMOTE_RC=0 bash "$TARGET" sas@10.0.0.5 "it's.start" 'plain.end' true
rc=$?
log_contents="$(cat "$ARGS_FILE")"
assert_eq "exit 0" 0 "$rc"
assert_contains "single quote in marker survives" "it's.start" "$log_contents"
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
