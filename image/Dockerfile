# Claude Code Sandbox image.
#
# Security model lives here (internal policy) + in the host Wrapper (external run flags).
# See ../CONTEXT.md and ../docs/adr/. Everything below is auditable on purpose.
#
# Identities:
#   root   (uid 0)    - entrypoint only: sets up firewall + proxy, then drops to `claude` and is gone
#   claude (uid 1000) - runs Claude Code; firewall grants FULL internet (API, WebSearch, WebFetch)
#   runner (uid 1001) - runs every command AND every MCP server (Claude Code wraps MCP launches with
#                       $CLAUDE_CODE_SHELL_PREFIX too); firewall grants ONLY the registry-allowlist
#                       proxy, so context7 reaches its API via that allowlist, not full internet
#   proxy  (uid 1002) - the CONNECT-allowlist proxy that fronts package registries + context7 (no logging)

FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# --- Base toolchain (batteries-included: one image works across projects) ---
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg git openssh-client \
      build-essential pkg-config \
      python3 python3-pip python3-venv \
      golang-go \
      ripgrep jq less vim-tiny nano \
      sudo nftables tinyproxy gosu tini acl \
      locales \
    && rm -rf /var/lib/apt/lists/*

# --- Node.js 20 (for Claude Code + npm projects) ---
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- Claude Code CLI ---
# Pinned for reproducible builds (two builds yield the SAME CC version). Renovate bumps the ARG
# default via the annotation below; that edit touches image/** and so triggers a republish.
# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=2.1.216
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force

# --- pnpm (baked alongside npm; the agent picks per-project). Its store lives in runner's HOME
#     (/home/runner = the per-project cache volume), so installs persist across runs. ---
RUN npm install -g pnpm \
    && npm cache clean --force

# --- Rust (rustup, minimal profile) installed into a shared location ---
ENV RUSTUP_HOME=/opt/rust/rustup \
    CARGO_HOME=/opt/rust/cargo \
    PATH=/opt/rust/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path \
    && chmod -R a+rX /opt/rust

# --- Identities ---
# claude defaults to uid 1000 (typical host user); the entrypoint remaps it to the real HOST_UID
# at runtime so it can write the bind-mounted project. runner/proxy use high uids so they never
# collide with whatever host uid claude adopts.
RUN (userdel -r ubuntu 2>/dev/null || true); (groupdel ubuntu 2>/dev/null || true); \
    groupadd -g 1000 claude   && useradd -m -u 1000 -g 1000 -s /bin/bash claude \
    && groupadd -g 61001 runner && useradd -m -u 61001 -g 61001 -s /bin/bash runner \
    && useradd -r -u 61002 -g nogroup -M -d /nonexistent -s /usr/sbin/nologin ccproxy

# --- Policy files ---
COPY firewall.sh            /usr/local/sbin/cc-firewall
COPY entrypoint.sh          /usr/local/sbin/cc-entrypoint
COPY launch-claude.sh       /usr/local/bin/cc-launch-claude
COPY runner-exec.sh         /usr/local/bin/cc-runner-exec
COPY sudoers-cc             /etc/sudoers.d/cc-sandbox
COPY proxy/tinyproxy.conf   /etc/cc-sandbox/tinyproxy.conf
COPY proxy/registry-filter  /etc/cc-sandbox/registry-filter
COPY mcp/config.json        /etc/cc-sandbox/mcp.json

RUN chmod 0755 /usr/local/sbin/cc-firewall /usr/local/sbin/cc-entrypoint \
        /usr/local/bin/cc-launch-claude /usr/local/bin/cc-runner-exec \
    && chmod 0440 /etc/sudoers.d/cc-sandbox \
    && visudo -cf /etc/sudoers.d/cc-sandbox \
    && mkdir -p /workspace && chown claude:claude /workspace

# Harden: strip every setuid/setgid bit, then re-grant ONLY sudo (the single privilege path).
# This shrinks the escalation surface for the agent (which runs as non-root `claude`).
RUN find / -xdev -type f -perm /6000 -exec chmod a-s {} + 2>/dev/null || true; \
    chmod u+s /usr/bin/sudo

# Claude's home holds session state (~/.claude). Writable; ephemeral unless a volume is mounted.
# Real workdir is set at runtime (-w /workspace/<project-name>); this is just the parent default.
WORKDIR /workspace

# tini as PID 1 for proper signal/zombie handling; entrypoint runs as root then drops to claude.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/sbin/cc-entrypoint"]
