#!/usr/bin/env bash
# cc-firewall — per-uid egress policy (ADR-0001 enforcement).
#
# Run as root, ONCE, at container start (needs CAP_NET_ADMIN). After the entrypoint drops to the
# unprivileged `claude` user (no caps), these rules are immutable for the session.
#
#   claude (= CLAUDE_UID, the host uid) -> full internet  (agent: API, WebSearch, WebFetch, context7)
#   proxy  (61002)                      -> tcp 80/443 + DNS (fronts the registry allowlist)
#   runner (61001)                      -> loopback only    (can ONLY reach the proxy; else dropped)
#
# We ADD a dedicated table (no `flush ruleset`) so Docker's embedded-DNS NAT (127.0.0.11) survives.

set -euo pipefail

CLAUDE_UID="${CLAUDE_UID:-1000}"
PROXY_UID=61002

nft -f - <<EOF
table inet ccsandbox {
    chain output {
        type filter hook output priority 0; policy drop;

        ct state established,related accept
        oifname "lo" accept
        ip daddr 127.0.0.11 accept
        ip6 daddr ::1 accept

        # Agent: unrestricted egress. Exfil is bounded by secret confinement, not here (ADR-0001).
        meta skuid ${CLAUDE_UID} accept

        # Registry proxy: web + DNS ports. Hostname allowlist is enforced by tinyproxy, not here.
        meta skuid ${PROXY_UID} tcp dport { 80, 443 } accept
        meta skuid ${PROXY_UID} udp dport 53 accept
        meta skuid ${PROXY_UID} tcp dport 53 accept

        # runner: no accept rule -> only loopback (the proxy) reaches anything. Default drop.
        counter comment "cc-sandbox dropped-egress"
    }
}
EOF

echo "[cc-firewall] egress policy installed (claude uid=${CLAUDE_UID} full; runner proxy-only)" >&2
