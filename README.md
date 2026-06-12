# nix-agent-sandbox

Nix-built OCI runtime for fully autonomous AI coding agents (Claude Code,
Codex CLI, Gemini CLI). The container is the permission boundary: inside it,
every tool runs with all approvals bypassed; outside it, nothing changes
except a pushed branch/PR.

Architecture: [docs.jacobpevans.com/autonomous-agents](https://docs.jacobpevans.com/autonomous-agents/overview)

## What this repo owns

| Output | What it is |
| --- | --- |
| `packages.<linux>.agent-image` | `dockerTools.streamLayeredImage` with the three CLIs, git/gh/nix, and the autonomous configs baked from `dryvist/nix-ai` `lib.renderAutonomous.files`. Runs as `agent` (uid 1000), no sudo. |
| `packages.*.agent-cli` | `agent run\|shell` — dispatch via Apple `container` (macOS) or Docker. |
| `lib.egressDomains` | The egress allowlist shared by the (phase 2) proxy, docker-host nftables, and the docs. |
| `.github/workflows/build-image.yml` | Builds both architectures and publishes the multi-arch manifest to GHCR. |

## Installation

```sh
# Run the dispatch CLI directly from the flake
nix run github:dryvist/nix-agent-sandbox -- run --tool claude "task..."

# Or install it into a profile / home-manager packages
nix profile install github:dryvist/nix-agent-sandbox#agent-cli
```

The agent image itself is published by CI to
`ghcr.io/dryvist/nix-agent-sandbox/agent:latest` (multi-arch); the CLI
pulls it on first use. Building the image locally requires a Linux
builder: `nix build .#agent-image`.

## Usage

```sh
# One-shot autonomous run against a repo; output is a branch + PR
GH_TOKEN=<repo-scoped token> ANTHROPIC_API_KEY=... \
  agent run --tool claude --repo dryvist/some-repo "fix the flaky test in ci.yml"

# Debug shell inside the image
agent shell
```

The entrypoint refuses to start unless `AGENT_SANDBOX=1` (set only by the
image) and the uid is non-root. The autonomous configs are never rendered
onto a host filesystem by any code path.

## Safety model

- **Filesystem/process**: disposable container, non-root, `--rm`.
- **Credentials**: short-lived scoped tokens injected per run; the residual
  deny list (one shared list in `dryvist/nix-ai`, rendered into all three
  tools' native formats) blocks credential-borne damage like `gh repo
  delete` and force-pushes.
- **Network** (phase 2): allowlisting CONNECT proxy from `lib.egressDomains`.
- **Durability**: git. The branch/PR is the only thing that survives the run.
