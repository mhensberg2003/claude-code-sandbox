#!/usr/bin/env bash
# cc-sandbox installer. Drops the (small, auditable) Wrapper onto your PATH.
#
#   curl -fsSL https://raw.githubusercontent.com/REPLACE_ME_ORG/claude-code-sandbox/stable/install.sh | bash
#
# The Wrapper pulls the policy image (ghcr.io/.../cc-sandbox:stable) on each run via --pull=always,
# so security/policy updates reach you automatically — re-run this installer only when the Wrapper
# script itself changes.
set -euo pipefail

REPO="${CC_SANDBOX_REPO:-mhensberg2003/claude-code-sandbox}"
REF="${CC_SANDBOX_REF:-main}"
DEST="${CC_SANDBOX_BIN:-$HOME/.local/bin}"
URL="https://raw.githubusercontent.com/${REPO}/${REF}/bin/cc-sandbox"

echo "cc-sandbox installer"
command -v docker >/dev/null 2>&1 || echo "  ! Docker not found — you'll need it before running cc-sandbox."

mkdir -p "$DEST"
echo "  downloading $URL"
curl -fsSL "$URL" -o "$DEST/cc-sandbox"
chmod +x "$DEST/cc-sandbox"
echo "  installed -> $DEST/cc-sandbox"

case ":$PATH:" in
    *":$DEST:"*) ;;
    *) echo "  ! $DEST is not on your PATH. Add: export PATH=\"$DEST:\$PATH\"" ;;
esac

echo "Done. Usage:  cd <project> && cc-sandbox"
