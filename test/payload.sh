#!/usr/bin/env bash
# Runs in place of Claude Code, AS `claude`, after the entrypoint sets everything up.
# Exercises the REAL interposition path (cc-runner-exec), exactly as CLAUDE_CODE_SHELL_PREFIX would.
# No Claude quota is used. Exit non-zero if any property fails.
echo "================ CC-SANDBOX SECURITY HARNESS ================"
echo "agent id: $(id -un) ($(id -u))"
RX=/usr/local/bin/cc-runner-exec
fail=0
check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS  $1 ($3)"; else echo "  FAIL  $1 (expected $2, got $3)"; fail=1; fi
}

curl -sS -m 10 https://example.com -o /dev/null && a=OK || a=FAIL
check "agent-full-internet"        OK       "$a"

check "command-runs-as-runner"     runner   "$($RX 'id -un')"

$RX 'curl -sS -m 8 --noproxy "*" https://example.com -o /dev/null' && a=LEAK || a=BLOCKED
check "command-direct-egress"      BLOCKED  "$a"

$RX 'curl -sS -m 8 https://example.com -o /dev/null' && a=LEAK || a=BLOCKED
check "command-proxy-to-evil-host" BLOCKED  "$a"

check "command-proxy-to-registry"  200      "$($RX "curl -s -o /dev/null -w '%{http_code}' -m 15 https://registry.npmjs.org/")"

nft add rule inet ccsandbox output accept 2>/dev/null && a=POSSIBLE || a=CANNOT
check "firewall-immutable"         CANNOT   "$a"

sudo -n -u root id >/dev/null 2>&1 && a=ALLOWED || a=DENIED
check "no-sudo-to-root"            DENIED   "$a"

sudo -n -u runner id >/dev/null 2>&1 && a=OK || a=FAIL
check "sudo-drop-to-runner"        OK       "$a"

$RX 'touch /workspace/project/.cc-write-test && rm -f /workspace/project/.cc-write-test' && a=OK || a=FAIL
check "command-can-write-project"  OK       "$a"

# Host manageability: a dir+file CREATED BY runner must be deletable by claude (= the host uid), or
# sandbox-produced build artifacts / .git objects are un-removable on the host (EACCES). The
# unlink needs write on the runner-owned dir, which only the default-ACL grant for HOST_UID provides.
$RX 'mkdir -p /workspace/project/.cc-acltest && touch /workspace/project/.cc-acltest/f'
rm -f /workspace/project/.cc-acltest/f 2>/dev/null && a=OK || a=EACCES
check "host-uid-can-delete-runner-file" OK  "$a"
rmdir /workspace/project/.cc-acltest 2>/dev/null || $RX 'rm -rf /workspace/project/.cc-acltest' || true

$RX 'cat /home/claude/.claude/.credentials.json' >/dev/null 2>&1 && a=YES || a=NO
check "command-cannot-read-token"  NO       "$a"

echo "================ $([[ $fail == 0 ]] && echo ALL PASS || echo FAILURES) ================"
exit $fail
