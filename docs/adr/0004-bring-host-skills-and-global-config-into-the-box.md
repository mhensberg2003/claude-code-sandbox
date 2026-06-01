# Host skills and global CLAUDE.md/rules are copied into the box; plugins/MCP/secrets are not

Status: accepted (refines CONTEXT.md decision 8a — "the rest of Host `~/.claude` is excluded")

## Context

The Sandbox started with an empty `~/.claude` apart from the surgically-injected OAuth token and
onboarding markers (decision 8a). That means the agent inside the box had **none** of the
employee's skills, no global `CLAUDE.md`, and no `rules/` — so behavior diverged sharply from the
Host. The first reported friction was "my skills don't carry over."

The earlier blanket "exclude the rest of Host `~/.claude`" was the right default for *secrets and
config that carry credentials or leak other projects* (`mcpOAuth`, MCP server configs, project
history, sessions). It was too broad for **authored content** the employee deliberately maintains to
shape the agent: skills, the global `CLAUDE.md`, and `rules/`.

## Decision

The Wrapper stages the employee's Host `~/.claude/skills`, `~/.claude/CLAUDE.md`, and
`~/.claude/rules/` into the private secret dir and mounts it **read-only** at
`/run/cc-secret/user-claude`. The entrypoint copies it into the box's `~/.claude` (owned by
`claude`, writable in-box, never touching the Host originals).

- Skills are staged with `cp -L` (dereference symlinks): some Host skills are symlinks into
  `~/.agents/skills`, which would dangle inside the box. Dereferencing yields a self-contained tree
  and avoids exposing `~/.agents` as a mount.
- Opt out for a pristine box: `--no-config` or `CC_SANDBOX_NO_CONFIG=1`.

## Why this is consistent with the threat model

- **Not a credential.** Skills/`CLAUDE.md`/`rules` are content the employee authored and chose to
  bring; they carry no token. The 8a exclusions that *do* carry credentials or other projects
  (`mcpOAuth`, MCP configs, project history, sessions) remain excluded.
- **No new exfil channel.** Skill scripts run as `runner`/`claude` *inside* the Sandbox — behind the
  same immutable egress firewall and Project-only mount as everything else. The worst case is still
  bounded by secret confinement (ADR-0001 / decision 5c), unchanged.
- **Read-only crossing.** The Host copies are mounted `:ro`; the in-box copy is what the agent uses,
  so a compromised agent cannot rewrite the employee's Host skills.

## Explicitly NOT brought

Plugins (`~/.claude/plugins`, ~600MB — heavy, and a much larger surface), MCP servers, subagents,
`settings.json`, and history. Plugins were excluded on size/surface grounds; if the fleet needs a
specific plugin's skills, bake them into the image instead (central policy, like the MCP allowlist).

## Consequences

- A small per-launch copy (~1–2MB) into the ephemeral secret dir; negligible.
- Behavior inside the box now tracks the Host's skills and global instructions, so the box is a
  faithful environment rather than a blank one.
- New residual: a malicious *skill the employee already trusts on the Host* also runs in the box. But
  that skill already runs unsandboxed on the Host today, and in the box it is strictly more confined.
