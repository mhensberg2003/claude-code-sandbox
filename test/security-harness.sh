#!/usr/bin/env bash
# Runs the security harness against a built image, using the same locked flags the Wrapper applies.
# Swaps the Claude launcher for test/payload.sh so NO Claude quota is used.
#
#   ./test/security-harness.sh [image]
set -euo pipefail

IMAGE="${1:-cc-sandbox:dev}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/proj"
echo '{"claudeAiOauth":{"accessToken":"TEST","refreshToken":"x","expiresAt":0,"scopes":[],"subscriptionType":"max"}}' > "$WORK/credentials.json"
chmod 600 "$WORK/credentials.json"

docker run --rm \
  --cap-drop=ALL \
  --cap-add NET_ADMIN --cap-add SETUID --cap-add SETGID --cap-add CHOWN \
  --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add FSETID --cap-add SETPCAP --cap-add AUDIT_WRITE \
  --pids-limit 512 --memory 4g \
  --read-only --tmpfs /tmp --tmpfs /run --tmpfs /var/tmp \
  --tmpfs /home/claude:exec,mode=0700 --tmpfs /home/runner:exec,mode=0755 \
  -e HOST_UID=1000 -e HOST_GID=1000 \
  -v "$WORK/proj:/workspace/project" \
  -v "$WORK/credentials.json:/run/cc-secret/credentials.json:ro" \
  -v "$HERE/payload.sh:/usr/local/bin/cc-launch-claude:ro" \
  "$IMAGE"
