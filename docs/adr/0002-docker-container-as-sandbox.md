# Docker container as the Sandbox, not native bubblewrap/Seatbelt

Status: accepted

## Context

The Sandbox must enforce the same security policy on a fleet of employee laptops that are **WSL-primary with occasional macOS**. The strongest isolation primitives are OS-specific: bubblewrap/namespaces on Linux (incl. WSL2), Seatbelt (`sandbox-exec`) on macOS. The lighter path on our primary platform would have been native bubblewrap.

## Decision

The Sandbox is a **Docker container** built from a single image, run identically on WSL and macOS. Claude Code runs **inside** the container (not on the Host driving a sandboxed shell).

## Considered options

- **Native per-OS (bubblewrap + Seatbelt):** lighter, no daemon, faster startup on WSL. Rejected — it means maintaining and auditing **two** security policies for a security tool; a gap in either is a breach, forever.
- **microVM per session (Firecracker/gVisor):** stronger (Level C) but heavy to distribute and operate. Rejected as overkill for the threat model (Level B).

## Why

1. **Write the policy once.** Filesystem rules, the `claude`/`runner` firewall split, the toolchain — one Dockerfile, identical on every laptop. No per-OS drift in security-critical code.
2. **It matches Level B specifically.** The threat model assumes the *agent process itself* can be prompt-injected, so Claude Code must sit **inside** the boundary, not on the Host. A whole-session container puts the potentially-compromised process behind the boundary; per-command sandboxing (Claude on Host) would not.
3. **Network egress has a clean home.** Containers have their own network namespace, which is where the per-uid Command/Agent network split lives (see ADR-0001).

## Consequences

- **Dependency:** employees need Docker installed and running. Acceptable in a WSL + Mac dev shop; the Wrapper checks for it.
- **Bonus on macOS:** Docker runs in a Linux VM there, yielding a near-Level-C boundary for free.
- The Wrapper applies the **external** run policy (`--cap-drop`, mounts, network, `--rm`) the image cannot set itself, making the Wrapper co-load-bearing with the image (see CONTEXT.md, host-ownership boundary).
