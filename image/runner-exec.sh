#!/bin/sh
# cc-runner-exec — the command interposition point (ADR-0001).
#
# Claude Code prepends $CLAUDE_CODE_SHELL_PREFIX to every Bash-tool command, invoking us as a
# single-token command with the FULL command string as $1. We run that command as the unprivileged
# `runner` uid, so it lands on the registry-only network identity. The agent chooses the command
# string ($1), never the prefix, so it can never get a command back onto the full-internet `claude`
# identity.
#
# `runner` reaches the internet ONLY via the registry-allowlist proxy, set here.
set -eu

PROXY="http://127.0.0.1:8118"

# -n: never prompt. -E (+ SETENV in sudoers): carry the agent's intended command env through.
# The explicit proxy/HOME vars are last so they always win for `runner`.
exec sudo -n -E -u runner /usr/bin/env \
    HTTP_PROXY="$PROXY"  HTTPS_PROXY="$PROXY" \
    http_proxy="$PROXY"  https_proxy="$PROXY" \
    NO_PROXY="127.0.0.1,localhost,::1" no_proxy="127.0.0.1,localhost,::1" \
    HOME=/home/runner USER=runner \
    /bin/bash -c "$1"
