# Claude Code Sandbox

Run Claude Code with `--dangerously-skip-permissions` **safely**, so the agent can work unattended
without being able to damage your machine, escape the project, or quietly exfiltrate your secrets.

```bash
cd my-project
cc-sandbox
```

That launches Claude Code inside a hardened Docker container scoped to the current project. The agent
gets full reasoning power and internet; the **commands it runs** get no network except package
registries; and **nothing on your host** — SSH keys, cloud creds, other projects — is reachable.

> Built for a team. The security policy is baked into a central image and applies the same on every
> laptop (WSL primary, macOS supported). See [`CONTEXT.md`](./CONTEXT.md) for the full design and
> [`docs/adr/`](./docs/adr/) for the load-bearing decisions.

---

## Threat model (what "safe" means here)

Level **B — adversarial content**: assume a malicious repo, dependency, or web page can prompt-inject
the agent. The Sandbox defends against that. It does **not** assume the agent will mount a kernel
breakout (Level C / per-session VM), and it does **not** try to stop *you* from sabotaging your own
laptop (you own the host — see "Boundaries").

**Worst case if the agent is fully compromised:** it can leak *this one project's source* and *your
own Claude login token* (rotatable via `claude login`) — via WebFetch. It cannot reach your host
credentials, other projects, MCP-connected accounts, or run autonomous command-network malware.

## How it works

| Layer | Policy |
|---|---|
| **Agent** (Claude itself, uid `claude`) | **Full internet** — API, WebSearch, WebFetch, context7 MCP |
| **Commands** (every Bash command, uid `runner`) | **No network except a registry allowlist** (npm/PyPI/Go/crates/…) via a no-log CONNECT proxy |
| **Filesystem** | Only the current project is mounted (read-write). No `$HOME`, no host env, no SSH/cloud creds |
| **Auth** | Only your `claudeAiOauth` token is injected (never `mcpOAuth` or anything else) |
| **Skills & global config** | Your `~/.claude/skills`, `CLAUDE.md`, and `rules/` are copied in read-only (symlinks dereferenced) so the agent behaves like it does on the host. Opt out with `--no-config`. **Not** brought: plugins, MCP servers, subagents, history |
| **Firewall** | Per-uid `nftables`, set once by root then made immutable (agent can't disable it) |
| **Hardening** | read-only rootfs, dropped caps, pids/memory limits, no Docker socket, ephemeral container |
| **Git** | Agent commits (name/email injected); **never** pushes — you push from the host after review |

The split is enforced by `CLAUDE_CODE_SHELL_PREFIX`, which routes every agent command through a
wrapper that drops to the `runner` identity. Details in [ADR-0001](./docs/adr/0001-network-posture-secret-confinement-not-egress.md).

## Install

Requires **Docker** installed and running.

```bash
curl -fsSL https://raw.githubusercontent.com/mhensberg2003/claude-code-sandbox/main/install.sh | bash
```

This drops the small, auditable `cc-sandbox` Wrapper onto your `PATH`. The policy image is pulled
from GHCR (`:stable`) on each run via `--pull=always`, so security fixes reach you automatically —
re-run the installer only when the Wrapper script itself changes.

First time: run `claude login` on your host once so the Wrapper can extract your OAuth token.

## Usage

```bash
cc-sandbox                # launch in the current project (new conversation; session is saved)
cc-sandbox --resume       # pick a past session for this project to resume (native picker)
cc-sandbox --fresh        # wipe this project's cached deps AND saved sessions first
cc-sandbox --ephemeral    # no on-disk session state (not resumable)
cc-sandbox --no-config    # pristine box: skip your host skills / global CLAUDE.md / rules
cc-sandbox --update       # update the Wrapper + pull the latest image, then exit
cc-sandbox --export-session  # copy this project's sandbox sessions to the host, then `claude --resume`
cc-sandbox --unsafe       # ESCAPE HATCH: plain `claude --dangerously-skip-permissions`, NO sandbox
cc-sandbox -- -p "..."    # pass arguments through to claude
```

**Updating:** the policy image auto-updates on every run (`--pull=always`). To also refresh the
Wrapper script itself, run `cc-sandbox --update` (or re-run the installer).

Sessions are saved per-project in a **local** Docker volume so `--resume` works; nothing leaves your
machine. Use `--ephemeral` if you want zero session state on disk.

The box publishes **no host ports**, so it never occupies ports (3000, 5173, …) your own host dev
servers use. Run dev servers on the host as usual. If you need to reach a server running *inside* the
box, publish it yourself with a one-off `docker run -p ...` (or use `--unsafe`).

## Boundaries (read this)

- **The Sandbox protects against the agent/repo/dependencies, not against you.** The Wrapper is a
  file on a machine you own; you *can* weaken it (edit it, or use `--unsafe`). The goal is
  **safe-by-default, with bypass being loud and deliberate** — not "impossible to bypass."
- **WebFetch is not restricted by destination.** That's a deliberate trade (see ADR-0001): the agent
  can fetch any URL, so it can also exfil project source. Exfil is bounded by *secret confinement*,
  not the network. If that's too loose for you, tighten `claude`'s egress (see ADR-0001's note).

## Customizing (central, not per-employee)

These live in the image so the policy stays consistent across the fleet — edit and rebuild/publish:

- **Registry allowlist** (incl. your internal registry): `image/proxy/registry-filter`
- **Toolchain**: `image/Dockerfile`
- **Allowed MCP servers** (default: context7 only): `image/mcp/config.json`
- **Image location**: set `IMAGE` in `bin/cc-sandbox` to your `ghcr.io/<org>/...:stable`

Publishing is automated by [`.github/workflows/publish-image.yml`](./.github/workflows/publish-image.yml)
(pushes `:stable` to GHCR on changes to `image/`).

## Local development

```bash
docker build -t cc-sandbox:dev ./image
CC_SANDBOX_IMAGE=cc-sandbox:dev cc-sandbox     # use your local build instead of GHCR
```

## Security properties (validated)

The model is verified end-to-end against the built image (`image/` + Wrapper):

- agent has full internet; commands are blocked from all direct egress
- commands can reach allowlisted registries (npm → `200`) but not arbitrary hosts (`example.com` → refused)
- the agent cannot modify the firewall or `sudo` to root; it can only drop to `runner`
- commands run as `runner` yet can still write the project (via ACLs)
- the injected OAuth token is not even readable by `runner` commands
