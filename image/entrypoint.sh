#!/usr/bin/env bash
# cc-entrypoint — runs as root, sets up the box, then drops to `claude` and is gone.
# After the final exec, NO root process remains reachable by the agent.
set -euo pipefail
log() { echo "[cc-entrypoint] $*" >&2; }

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
# Where the project is mounted in-box. The Wrapper sets this to /workspace/<project-name> so paths
# and the prompt reflect the real project; fall back to the legacy generic path if it's unset.
PROJECT_DIR="${CC_PROJECT_PATH:-/workspace/project}"

# --- 1. Remap `claude` to the real host uid/gid so it can write the bind-mounted project --------
if [[ "$(id -u claude)" != "$HOST_UID" ]]; then
    groupmod -g "$HOST_GID" claude 2>/dev/null || true
    usermod  -u "$HOST_UID" -g "$HOST_GID" claude
    chown -R "$HOST_UID:$HOST_GID" /home/claude
fi
export CLAUDE_UID="$HOST_UID"

# --- 2. Egress firewall (fail loud; never fail open) -------------------------------------------
if ! CLAUDE_UID="$HOST_UID" /usr/local/sbin/cc-firewall; then
    log "FATAL: could not install egress firewall — refusing to start."
    exit 1
fi

# --- 3. Registry allowlist proxy ---------------------------------------------------------------
install -d -o ccproxy -g nogroup -m 0755 /run/cc-sandbox
tinyproxy -c /etc/cc-sandbox/tinyproxy.conf
log "registry-allowlist proxy up on 127.0.0.1:8118"

# --- 4. Writable homes (rootfs is read-only; these are tmpfs/volumes) ---------------------------
install -d -o claude -g claude -m 0700 /home/claude/.claude
chown "$HOST_UID:$HOST_GID" /home/claude /home/claude/.claude 2>/dev/null || true
install -d -o runner -g runner -m 0755 /home/runner

# --- 5. Surgical OAuth: copy ONLY the injected token into claude's home (accepted exfil risk) ---
if [[ -f /run/cc-secret/credentials.json ]]; then
    install -o claude -g claude -m 0600 /run/cc-secret/credentials.json /home/claude/.claude/.credentials.json
    log "injected Claude OAuth token"
else
    log "WARNING: no credentials injected — Claude Code will be unauthenticated."
fi

# --- 5b. Seed ~/.claude.json: onboarding/account markers + pre-trust the project --------------
# The project is mounted at $PROJECT_DIR and the container IS the trust boundary, so the
# folder-trust dialog inside the box is redundant — pre-accept it so Claude never prompts.
TRUST="$(jq -nc --arg p "$PROJECT_DIR" \
    '{projects: {($p): {hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true, projectOnboardingSeenCount: 1}}}')"
if [[ -f /run/cc-secret/claude-config.json ]]; then
    jq -s '.[0] * .[1]' /run/cc-secret/claude-config.json <(printf '%s' "$TRUST") > /home/claude/.claude.json 2>/dev/null \
        || printf '%s' "$TRUST" > /home/claude/.claude.json
else
    printf '%s' "$TRUST" > /home/claude/.claude.json
fi
chown "$HOST_UID:$HOST_GID" /home/claude/.claude.json && chmod 600 /home/claude/.claude.json

# --- 6. Curated MCP config (context7 only); never the Host's MCP servers ------------------------
install -o claude -g claude -m 0600 /etc/cc-sandbox/mcp.json /home/claude/.claude/.mcp.json 2>/dev/null || true

# --- 6b. User-authored skills + global CLAUDE.md/rules (copied read-only from host, opt-out) -----
# The Wrapper staged these (symlinks already dereferenced). Copy into claude's home so the agent
# has the same skills / global instructions it does on the host. Owned by claude, writable in-box
# but never touching the host originals.
if [[ -d /run/cc-secret/user-claude ]]; then
    cp -r /run/cc-secret/user-claude/. /home/claude/.claude/ 2>/dev/null || true
    chown -R "$HOST_UID:$HOST_GID" /home/claude/.claude 2>/dev/null || true
    log "seeded host skills + global CLAUDE.md/rules"
fi

# --- 7. Git identity (name/email only; never credentials) --------------------------------------
[[ -n "${GIT_AUTHOR_NAME:-}"  ]] && gosu claude git config --global user.name  "${GIT_AUTHOR_NAME}"  || true
[[ -n "${GIT_AUTHOR_EMAIL:-}" ]] && gosu claude git config --global user.email "${GIT_AUTHOR_EMAIL}" || true
# The project is owned by `claude` but commands run as `runner`; trust it for both so git doesn't
# trip "dubious ownership" on every command.
gosu claude         git config --global --add safe.directory "$PROJECT_DIR" || true
sudo -n -u runner   git config --global --add safe.directory "$PROJECT_DIR" || true

# --- 8. Grant `runner` write access to the project WITHOUT changing ownership -------------------
# Commands run as runner but the project is owned by the host uid (= claude). ACLs let runner
# create/rename files (npm install, build outputs) while keeping claude as the real owner.
if [[ -d "$PROJECT_DIR" ]]; then
    setfacl -R  -m u:runner:rwX "$PROJECT_DIR" 2>/dev/null || log "note: could not set ACLs (non-ext4 mount?) — continuing"
    setfacl -Rd -m u:runner:rwX "$PROJECT_DIR" 2>/dev/null || true
fi

# --- 9. Hand off to the agent as unprivileged `claude`. Firewall is now immutable for it. -------
cd "$PROJECT_DIR" 2>/dev/null || cd /workspace
log "launching Claude Code as claude (uid=${HOST_UID})"
exec gosu claude env \
    HOME=/home/claude USER=claude SHELL=/bin/bash \
    CLAUDE_CODE_SHELL_PREFIX=/usr/local/bin/cc-runner-exec \
    PATH="/opt/rust/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    /usr/local/bin/cc-launch-claude "$@"
