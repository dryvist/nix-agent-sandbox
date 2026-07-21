# nix-agent-sandbox

Nix-built OCI runtime for fully autonomous AI coding agents (Claude Code,
Codex CLI, Gemini CLI). The container is the permission boundary: inside it,
every tool runs with all approvals bypassed; outside it, nothing changes
except a pushed branch/PR.

Architecture: [docs.jacobpevans.com/autonomous-agents](https://docs.jacobpevans.com/autonomous-agents/overview)

## What this repo owns

| Output | What it is |
| --- | --- |
| `packages.<linux>.agent-image` | OCI image: the three CLIs, git/gh/nix, configs baked from nix-ai `lib.renderAutonomous.files`. Non-root, no sudo. |
| `packages.*.agent-cli` | `agent run\|sweep\|shell` — dispatch via Apple `container` (macOS) or Docker, locally or on the docker-host VM via `--host`. |
| `lib.egressDomains` | The egress allowlist enforced by the docker-host CONNECT proxy (ansible-proxmox-apps `agent_sandbox`). |
| `lib.taskProfiles` | Task profiles: the pre-defined OpenBao KV secret group each `--profile` grants. |
| `lib.repoGroups` | Named repo groups for `agent sweep` fan-out (baked into the CLI as JSON). |
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
# One-shot autonomous run against a repo; output is a branch + PR. The
# workstation's subscription-OAuth credentials for --tool claude are
# injected into the container automatically (no ANTHROPIC_API_KEY needed).
# Prefer `claude setup-token` once and export CLAUDE_CODE_OAUTH_TOKEN — a
# long-lived token, so no per-run file copy and no refresh-rotation risk.
GH_TOKEN=<repo-scoped token> \
  agent run --tool claude --repo dryvist/some-repo "fix the flaky test in ci.yml"

# API-key auth instead of subscription OAuth: skip injection with --no-oauth
GH_TOKEN=<repo-scoped token> ANTHROPIC_API_KEY=... \
  agent run --tool claude --no-oauth --repo dryvist/some-repo "fix the flaky test in ci.yml"

# Same, on the docker-host VM inside its egress-allowlisted network, with
# the task profile's KV secret group fetched from OpenBao inside the
# container. AppRole material defaults to the ambient AI_READONLY_* pair;
# ai-apply tiers pass a human-minted single-use BAO_WRAPPED_SECRET_ID instead.
#
# --repo additionally has the *launcher* (not the container) mint a
# per-run repo-scoped GitHub App token via the github-write OpenBao
# identity. Needs OPENBAO_APPROLE_GITHUB_WRITE_ROLE_ID/_SECRET_ID and the
# matching OPENBAO_GITHUB_<DRYVIST|PERSONAL>_INSTALLATION_ID.
BAO_ADDR=https://openbao.example.internal \
  agent run --host docker-host.example.internal --profile dev \
  --repo dryvist/some-repo "fix the flaky test in ci.yml"

# Fan the same task across every repo in a named group (lib.repoGroups),
# one disposable container per repo — each with its own repo-scoped token,
# just like `agent run --repo`. At most --concurrency run at once (default
# 4); an end-of-run table lists each repo, base branch, and PR URL or exit
# code. The group's profile is the default unless --profile overrides it.
BAO_ADDR=https://openbao.example.internal \
  agent sweep --group nix --host docker-host.example.internal \
  "bump the flake.lock and open a PR"

# Debug shell inside the image (add --host to debug on the docker host)
agent shell
```

The entrypoint refuses to start unless `AGENT_SANDBOX=1` (set only by the
image) and the uid is non-root. The autonomous configs are never rendered
onto a host filesystem by any code path.

## Safety model

- **Filesystem/process**: disposable container, non-root, `--rm`.
- **Transcripts**: a `--host` run bind-mounts a per-run host spool dir onto each
  CLI's transcript subdir (`~/.claude/projects`, `~/.codex/sessions`,
  `~/.gemini/tmp`) under `/var/lib/agent-sandbox/spool/<run-id>/`, so the session
  records outlive `--rm`. A host-side Cribl Edge tails them to Splunk; the
  ansible `agent_sandbox` role creates the spool root and prunes runs older than
  7 days. Only the transcript subdirs are mounted — never the state-home roots,
  which hold the baked autonomous configs and the injected OAuth creds.
- **Credentials**: subscription-OAuth creds for the selected `--tool` are read
  from the workstation (claude: an exported `CLAUDE_CODE_OAUTH_TOKEN` from
  `claude setup-token` if present, else `~/.claude/.credentials.json`, else
  the macOS Keychain; codex: `~/.codex/auth.json`; gemini:
  `~/.gemini/oauth_creds.json` and its companion files) and streamed into the
  container via `docker cp` between create and start — never baked into the
  image, never passed via `-e`/`docker run -e` (which would leak into
  `docker inspect` and remote shell history). A missing source credential, or
  (for claude/gemini, which expose a checkable expiry) one already expired,
  is a hard failure naming what to refresh — not a silent no-op that burns a
  whole run before failing inside the container.
  `--no-oauth` skips this for API-key auth instead. The residual deny list
  (one shared list in `dryvist/nix-ai`, rendered into all three tools'
  native formats) blocks credential-borne damage like `gh repo delete` and
  force-pushes regardless of which auth path is used.
  Risk: an OAuth refresh occurring inside the container could rotate the
  token and leave the workstation's copy stale, since both would then be
  racing to hold the current refresh token. Not yet observed in canary use;
  treat a "please re-authenticate" prompt on the workstation after an agent
  run as the signal to watch for.
- **Network**: on the docker-host, containers join an internal-only Docker
  network whose sole route out is a CONNECT proxy allowlisting
  `lib.egressDomains` (ansible-proxmox-apps `agent_sandbox` role).
- **Secrets**: `--profile` fetches a pre-defined KV group from OpenBao inside
  the container; AppRole material is unset before any agent tool starts, and
  write-tier grants are single-use human-wrapped secret_ids. `--repo` mints a
  per-run repo-scoped GitHub App token (≤1h) on the launcher via the
  workstation-only `github-write` identity — the container itself never holds
  GitHub write reach.
- **Durability**: git. The branch/PR is the only thing that survives the run.
