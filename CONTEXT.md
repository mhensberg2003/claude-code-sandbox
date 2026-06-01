# Claude Code Sandbox

A wrapper that launches Claude Code with `--dangerously-skip-permissions` inside an enforced isolation boundary, so the agent can run unattended without being able to damage the host, escape the project, or reach the network from the commands it runs. Intended for distribution to a team of employees.

## Language

**Sandbox**:
The enforced isolation boundary the agent runs inside. Confines the filesystem to the project and blocks command-initiated network access.
_Avoid_: jail, container (container is one possible *implementation* of the Sandbox, not a synonym)

**Wrapper**:
The single command an employee runs instead of `claude`. It builds/enters the Sandbox and launches Claude Code inside it.
_Avoid_: launcher, script

**Project**:
The directory the employee `cd`s into and wants the agent to work on. The only host location the agent may write to.
_Avoid_: workspace, repo

**Host**:
The employee's real machine, outside the Sandbox. Must be protected from the agent.

**Command network**:
Network access available to shell commands the agent runs (e.g. `curl`, `npm install`). This is **blocked**.
_Avoid_: conflating with the agent's own API/web access.

**Agent network**:
Network access Claude Code itself needs — the Anthropic API, web search, web fetch. This is **allowed**, and must be separable from Command network.

## Decisions

**Threat model: Level B — adversarial content.**
The Sandbox must defend against a malicious repo, dependency, or web page prompt-injecting the agent into exfiltrating secrets or attacking the network — not just honest mistakes (Level A). It does *not* assume the agent will attempt kernel-level breakout of the Sandbox itself (Level C / per-session VM), which is judged overkill for the distribution target.
Implication: filesystem confinement **plus** network egress control that the agent cannot disable from inside.

**Mechanism: a Docker container is the Sandbox.**
One image, identical behavior on WSL and macOS, so the security policy is written and audited once instead of as two native policies (bubblewrap + Seatbelt). Claude Code runs *inside* the container (not on the Host driving a sandboxed shell), because Level B assumes the agent process itself can be prompt-injected and must sit behind the boundary. Cost accepted: employees must have Docker installed/running. On macOS the container runs in a Linux VM, yielding a near-Level-C boundary for free.

**Network model: process-based split (Option 4), with Claude unrestricted by destination (5c-hardened, no proxy).**
- **Command network = zero.** Every command the agent runs launches into an empty network namespace (no interfaces, no DNS). The agent cannot undo this: the empty-netns launch is built into the shell Claude uses, and the container drops `NET_ADMIN` so even in-container root cannot rewrite it. This kills *autonomous* supply-chain malware (post-install beacons, second-stage payload downloads) regardless of agent decisions.
- **Agent network = full internet.** Claude itself reaches any host, so WebFetch works everywhere. WebSearch works (server-side via Anthropic). **No egress logging proxy** (declined for simplicity).
- **Consequence (accepted residual risk):** a prompt-injected agent can exfiltrate the current **Project's** source via WebFetch to an arbitrary host, silently. This is accepted. The defense against exfil therefore rests *entirely* on **secret confinement** — see decision below — so that the worst-case leak is the one Project's source the employee is already working on, never Host credentials or other projects.

This is a deliberate narrowing of Level B: the network is no longer the exfil boundary for Claude; the filesystem/secret boundary is.

**Dependency fetching: registry allowlist for commands (6a).**
Commands' network namespace is not literally empty after all — it may reach a curated allowlist of package registries (npm, PyPI, Go proxy, crates.io, internal registry, …) via destination firewall rules (no proxy). This restores normal `npm/pip/go/cargo install` flow while still killing arbitrary-host beacons. Accepted residual: malware *hosted on a real registry* can still be pulled — but that supply-chain risk exists with or without the Sandbox, so the Sandbox doesn't worsen it. Note: this means commands can technically reach registry hosts, a minor exfil channel that only matters if Claude is ever retightened to 5a/5b.

**Registry allowlist** (term):
The curated set of package-registry hosts that **Command network** may reach. The single exception to "commands get zero network."

**Filesystem confinement: Project-only.**
The Sandbox bind-mounts only the **Project** (read-write) and nothing else from the Host — no `$HOME`, `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config`, `~/.claude.json`. Host environment variables are **not inherited**; the container gets a curated minimal env. The toolchain comes from the image. Worst-case exfil is therefore exactly one Project's source.
- **Git identity:** the Wrapper injects only `user.name` / `user.email` into the box (no credentials).
- **Git push:** the agent commits but **never pushes**. The human pushes from the Host after reviewing the agent's commits. ("Sandbox does the work; Host releases it.") No Git credential ever enters the box.

**Authentication: 8a-surgical (OAuth token injected into the box).**
Employees authenticate via Claude Code OAuth (personal Claude subscription), not an API key. The credential cannot be hidden from the agent, because the agent's Read/Bash tools run *as Claude itself* — anything Claude can read to authenticate, the agent can read to steal. A key-off-box auth proxy was rejected: for OAuth it would require a TLS-terminating MITM of `api.anthropic.com` (to inject the Bearer header and handle token refresh), exposing all prompt/response traffic — worse than the problem.
- The Wrapper extracts **only** `claudeAiOauth` from the Host credential store (`~/.claude/.credentials.json` on WSL, Keychain on macOS) and writes it into the container's own `~/.claude/.credentials.json`.
- It also injects four **onboarding/account markers** from Host `~/.claude.json` (`userID`, `hasCompletedOnboarding`, `lastOnboardingVersion`, `oauthAccount`) into a minimal container `~/.claude.json` — required because Claude Code runs first-time login if these are absent, *even with a valid token*. These are low-sensitivity account identifiers, not secrets.
- Explicitly excluded: `mcpOAuth` (MCP server tokens — Gmail, Linear, etc.), the **rest** of `~/.claude.json` (project history, MCP configs), and the rest of Host `~/.claude` (history, sessions, plugins, settings).
- **Accepted residual risk:** an injected agent can exfil this token. Blast radius is bounded to the individual's own Claude subscription (quota abuse / login reuse), never a shared company key or their MCP-connected accounts. Rotation = re-run `claude login`.

**Skills & global config: brought in (authored content, not secrets).**
The Wrapper copies the employee's Host `~/.claude/skills`, `~/.claude/CLAUDE.md`, and `~/.claude/rules/` into the box (read-only stage, symlinks dereferenced with `cp -L` so links into `~/.agents/skills` don't dangle), so the agent has the same skills and global instructions it does on the Host. This is authored content the employee chose to bring, not a credential, and skill scripts execute *inside* the Sandbox — the safe place to run them, behind the same egress boundary as everything else. No new exfil channel beyond the accepted 5c WebFetch risk. Plugins (`~/.claude/plugins`, ~600MB), MCP servers, subagents, settings, and history are **not** brought. Opt out for a pristine box with `--no-config` / `CC_SANDBOX_NO_CONFIG=1`.

**Command interposition: `CLAUDE_CODE_SHELL_PREFIX`.**
Claude Code does *not* honor a custom `$SHELL` for its Bash tool, but it prepends the env var
`CLAUDE_CODE_SHELL_PREFIX` to every command (as a single-token wrapper receiving the full command as
`$1`). We set it to `/usr/local/bin/cc-runner-exec`, which `sudo`-drops to `runner` with the proxy
env. This is the load-bearing hook that makes the process-split actually apply to agent commands;
verified end-to-end (`id -un` → `runner`). The agent picks the command string, never the prefix.

**Project writability across the uid-split: ACLs + uid remap.**
Commands run as `runner` but the Project is owned by the Host uid (= `claude` after remap). The
entrypoint remaps `claude` to the real `HOST_UID` (so the agent owns the Project) and grants `runner`
write via POSIX ACLs (`setfacl`, default ACL for new files) — without changing ownership. This is why
`npm install` (as `runner`) can write `node_modules`/lockfiles into a Host-owned tree.

**Enforcement mechanism: per-uid firewall (9a) + registry CONNECT proxy (ADR-0003).**
The process-split is enforced inside the single container by `nftables` owner rules, not per-command netns plumbing.
- **root** runs only in the entrypoint: sets up nftables, then execs Claude as `claude` and exits the privileged context. No root process remains reachable by the agent.
- **`claude`** (the agent's uid) → firewall allows **full internet** (API, WebSearch, WebFetch/5c). Has no `NET_ADMIN` and is not root, so it cannot edit the firewall.
- **`runner`** → firewall allows **Registry allowlist only**. Every command runs here.
- The installed shell *is* a wrapper that drops `claude`→`runner` via `sudo`, locked to that single transition (never `claude`→root). The agent chooses the command string, never the shell, so **it can never move a command back onto the full-internet identity.**
- After setup, `NET_ADMIN` is dropped so the rules are immutable for the session.
- **Parked:** MCP servers run as children of the node process (uid `claude`) → full internet. Likely disable MCP servers inside the Sandbox.

**Lifecycle: ephemeral container, narrow persistence.**
- Container runs with `--rm`; the box itself keeps nothing between runs.
- Project-local deps (`node_modules`, `.venv`, …) persist for free via the Project bind-mount.
- Package-manager *global* caches (`~/.npm`, pip cache, Go module cache) persist in a **per-Project named volume**, purely for install speed. Wipeable via `--fresh`.
- **Sessions are fresh by default** (no history persisted). Resume is **opt-in**; when opted in, an extra volume stores the conversation transcript (which may contain secrets the agent read) — documented as such.

**Distribution & policy ownership: central signed image + thin Wrapper (11a).**
- **Image** is built centrally and published to **public GHCR** under a trusted moving tag (`:stable`). Internal policy (nftables, `claude`/`runner` split, sudo lock, Registry allowlist, toolchain) lives in the image. The Wrapper runs `docker run --pull=always …:stable`, so **policy/security fixes propagate to the whole fleet on next run** with no re-install.
- **Wrapper** is a small, auditable script in a **public repo** (transparency is a feature for a security tool). It is *co-load-bearing*: it applies the **external** run policy the image can't set itself — `--cap-drop=ALL`, mounts (Project rw, cache volume), network mode, `--rm` — plus the surgical OAuth extraction (Host file on WSL / Keychain on macOS). Delivery is incidental (curl a pinned release, brew tap, or download to PATH); it changes rarely since logic lives in the image.
- **Defense in depth:** the image entrypoint *re-drops* caps and *re-asserts* the firewall internally, so a forgotten external flag still fails safe. (A wrongly-added Host mount cannot be undone from inside — see boundary below.)
- **Escape hatch:** a loud, documented `--unsafe` flag runs plain `claude --dangerously-skip-permissions` with **no** Sandbox — the sanctioned, visible pressure valve, so employees flip a labeled switch instead of silently gutting a rule.

**Host-ownership boundary (by design, not a gap):**
The Wrapper is a file on a machine the employee owns. The Sandbox therefore guarantees **"safe by default; bypass is loud and deliberate,"** *not* "bypass is impossible." This is consistent with the threat model: the Sandbox defends against the **agent / repo / dependencies** (Level B), not against an employee choosing to sabotage their own laptop.

**Container hardening defaults.**
`--pids-limit` (fork-bomb guard), `--memory`/`--cpus` caps (tunable via Wrapper flags), read-only root filesystem + `tmpfs /tmp` (only Project, cache volume, and `/tmp` writable), no host devices, no `--privileged`, all caps dropped, and the Docker socket is **never** mounted. The `claude`→`runner` privilege drop uses **locked `sudoers`** (single transition, never to root) rather than `--security-opt=no-new-privileges`, which would neuter the `setuid` path the drop relies on — a deliberate, documented exception.

**MCP servers: disabled by default, curated allowlist.**
The Sandbox ships its **own** MCP config (never the Host's `~/.claude.json`), containing only an explicitly-permitted allowlist of low-risk, read-only servers. **v1 allowlist = context7** (doc lookup: `resolve-library-id`, `query-docs`). context7 runs as uid `claude` (full internet) and adds **no new exfil channel** beyond the accepted 5c WebFetch risk. All credential-bearing MCP servers (Gmail, Linear, …) are absent because `mcpOAuth` is never injected.

**Toolchain: one batteries-included image.**
The image is the only toolchain (Host not mounted), so `:stable` bakes in node, python, go, rust, git, build-essential, ripgrep, and common CLIs. Chosen over slim per-stack variants so it "just works" across any project for the fleet. Future opt-in extension: a project-level `Dockerfile.sandbox` that `FROM`s the base (not v1).

**Dev servers: common ports auto-forwarded.**
A curated set of common dev ports (e.g. 3000/3001/5173/8080/8000/4200/5000) is published container→Host automatically, each bound to **`127.0.0.1`** on the Host (never `0.0.0.0`). Inbound-from-localhost is not an exfil path, so this is safe. `runner` can bind/listen normally (the firewall filters egress, not listening).

## Relationships

- The **Wrapper** creates a **Sandbox** around the **Project** and launches Claude Code inside it
- The **Sandbox** gives Claude (**Agent network**) full internet but gives commands (**Command network**) only the **Registry allowlist**
- Exfil resistance depends on **secret confinement** (Project-only mount, surgical OAuth, no `mcpOAuth`), not on the network boundary
- The **Sandbox** protects the **Host** from the agent; it does **not** protect the Host from the *employee* (host-ownership boundary)
- Policy lives in the **central image** (internal rules) + the **Wrapper** (external run flags); both are co-load-bearing

## Example dialogue

> **Employee:** "If commands have no network, how does `npm install` work?"
> **Designer:** "Commands reach the **Registry allowlist** — npm, PyPI, etc. — and nothing else. A package *download* works; a post-install script beaconing to `evil.com` doesn't."
>
> **Employee:** "But the agent can still `WebFetch` my code out to anywhere?"
> **Designer:** "Yes — that's the accepted 5c trade. We don't stop exfil at the network; we stop it at the box. The only thing in the box is this one **Project** and your own surgically-injected Claude token. Your cloud keys, SSH, other clients' code, MCP logins — none of it is reachable, so that's the ceiling on what can leak."

## Flagged ambiguities

- "network access" → split into **Command network** (Registry allowlist only) vs **Agent network** (full internet). The central technical challenge, resolved via per-uid firewall (9a).
- "sandbox should be tamper-proof" → resolved to **safe-by-default; bypass is loud and deliberate**, because the Wrapper runs on a Host the employee owns (host-ownership boundary).

## Flagged ambiguities

- "network access" was used for two different things — resolved into **Command network** (blocked) vs **Agent network** (allowed). This split is the central technical challenge.
