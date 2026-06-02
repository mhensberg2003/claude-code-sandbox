#!/usr/bin/env bash
# Runs the security harness against a built image, using the same locked flags the Wrapper applies.
# Swaps the Claude launcher for test/payload.sh so NO Claude quota is used.
#
#   ./test/security-harness.sh [image]
set -euo pipefail

IMAGE="${1:-cc-sandbox:dev}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="$HERE/../bin/cc-sandbox"

# Single source of truth: pull the EXACT run policy (caps, memory, pid limit) from the Wrapper so
# this harness can never drift from what real runs apply. Defines CAPS / MEMORY / PIDS_LIMIT.
[[ -x "$WRAPPER" ]] || { echo "cannot find Wrapper at $WRAPPER" >&2; exit 1; }
eval "$("$WRAPPER" --print-run-policy)"
CAP_ARGS=(); for c in "${CAPS[@]}"; do CAP_ARGS+=(--cap-add "$c"); done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/proj"
echo '{"claudeAiOauth":{"accessToken":"TEST","refreshToken":"x","expiresAt":0,"scopes":[],"subscriptionType":"max"}}' > "$WORK/credentials.json"
chmod 600 "$WORK/credentials.json"

docker run --rm \
  --cap-drop=ALL "${CAP_ARGS[@]}" \
  --pids-limit "$PIDS_LIMIT" --memory "$MEMORY" \
  --read-only --tmpfs /tmp --tmpfs /run --tmpfs /var/tmp \
  --tmpfs /home/claude:exec,mode=0700 --tmpfs /home/runner:exec,mode=0755 \
  -e HOST_UID=1000 -e HOST_GID=1000 \
  -v "$WORK/proj:/workspace/project" \
  -v "$WORK/credentials.json:/run/cc-secret/credentials.json:ro" \
  -v "$HERE/payload.sh:/usr/local/bin/cc-launch-claude:ro" \
  "$IMAGE"
