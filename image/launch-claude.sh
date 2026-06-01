#!/usr/bin/env bash
# cc-launch-claude — runs as `claude`. The single entry into Claude Code.
#
# - --dangerously-skip-permissions: the whole point; safe ONLY because of the surrounding Sandbox.
# - --mcp-config + --strict-mcp-config: use ONLY the curated context7 config, never any inherited source.
set -euo pipefail

exec claude \
    --dangerously-skip-permissions \
    --mcp-config /etc/cc-sandbox/mcp.json \
    --strict-mcp-config \
    "$@"
