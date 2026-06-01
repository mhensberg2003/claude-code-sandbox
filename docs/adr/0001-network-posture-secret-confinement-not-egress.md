# Claude has full internet; exfil is bounded by secret confinement, not the network

Status: accepted

## Context

The Sandbox exists to run Claude Code `--dangerously-skip-permissions` against a Level B threat model (assume a malicious repo/dependency/web page can prompt-inject the agent). The obvious reading of "block network in the sandbox" is to deny outbound traffic. A future reader will look at this design and reasonably ask: *"why does a 'no-network sandbox' let the agent reach the entire internet?"* This ADR records why.

## Decision

We split outbound traffic by **process**, not destination:

- **Commands** (the `runner` uid) get only a curated **Registry allowlist** (npm/PyPI/Go/…), nothing else.
- **Claude itself** (the `claude` uid) gets **full internet**, so `WebFetch`, `WebSearch`, the API, and the context7 MCP all work.

Exfil is therefore **not** stopped at the network layer. It is stopped at the **box**: the only things reachable inside are the one **Project's** source and the employee's own surgically-injected Claude OAuth token. Host credentials, other projects, SSH/cloud keys, and `mcpOAuth` are never present.

## Why (the real trade-off)

Three forces pushed us off the naive "deny all egress" path:

1. **`WebFetch` and `WebSearch` are twins on the wire.** `WebFetch` is a client-side fetch from inside the box to an arbitrary URL. You cannot allow "web search" while denying "fetch to evil.com" by destination — they are the same path. A destination allowlist (Anthropic-only) would have killed `WebFetch` entirely.
2. **OAuth makes a key-off-box auth proxy impractical.** Employees authenticate with a Claude subscription OAuth token, not an API key. Keeping that token out of the box would require a TLS-terminating MITM of `api.anthropic.com` (to inject the Bearer header and handle refresh), exposing all prompt/response traffic — worse than the problem. So a credential must live in the box regardless, which means *something* sensitive is always reachable, which means the network was never going to be the true boundary.
3. **Workflow.** The team needs `WebFetch` against arbitrary docs/APIs. Denying it pushes employees back to raw `claude --dangerously-skip-permissions` on the Host — strictly worse.

## Consequences

- **Accepted residual risk:** a prompt-injected agent can exfiltrate the current Project's source and the employee's own (rotatable, individual-blast-radius) Claude token, silently (no logging proxy, declined for simplicity). This is a deliberate narrowing of Level B.
- The **secret-confinement** decisions (Project-only mount, surgical `claudeAiOauth` injection, `mcpOAuth` excluded, no Host env) become **load-bearing** — they are the exfil defense, not a convenience. Weakening any of them silently widens the worst-case breach.
- Keeping **commands** at Registry-only still earns its place: it kills *autonomous* supply-chain malware (post-install beacons, second-stage downloads) regardless of agent decisions — a different attack class from agent-mediated exfil.
- If this is ever retightened (Claude → Anthropic-only or a short allowlist), the Registry allowlist becomes the weak point and `WebFetch` dies — revisit together.
