# The registry allowlist is enforced by a CONNECT-allowlist proxy, not firewall IP rules

Status: accepted (supersedes an assumption in CONTEXT.md decision 6a)

## Context

During design we assumed the Registry allowlist (decision 6a) could be "just destination firewall
rules — no proxy." Implementation proved that wrong: npm/PyPI/crates/etc. sit behind CDNs (Fastly,
CloudFront, Google) whose IP ranges are large and churn constantly. A static nftables IP allowlist
for these hosts is unmaintainable and leaky.

## Decision

Commands (`runner`) are firewalled to **loopback only**. A small **CONNECT-allowlist forward proxy**
(tinyproxy) runs on `127.0.0.1:8118` as an unprivileged `ccproxy` uid and is the sole path out for
commands. It allows CONNECT only to hostnames matching the curated `registry-filter`
(`FilterDefaultDeny Yes`); everything else is refused. It does **not** terminate TLS and does **not**
log.

## Why this still honors the earlier decisions

- It is **not** the logging proxy that was declined (ADR-0001 / decision 5c): different purpose
  (hostname allowlist for *commands*), no logging, no TLS interception.
- The agent cannot bypass it: `runner` can reach nothing but loopback (enforced by the immutable
  per-uid firewall), so a command that ignores `HTTP(S)_PROXY` and dials a raw IP is dropped.
- Hostname filtering is the *only* robust way to express "these registries and nothing else" given
  CDN IP churn.

## Consequences

- One more in-box process (the proxy), started by the entrypoint as `ccproxy`. If it dies, commands
  lose registry access (fail safe).
- The allowlist lives in `image/proxy/registry-filter` — part of the central, reviewed image policy.
  Adding an internal registry means editing that file and rebuilding (not an employee-side toggle).
