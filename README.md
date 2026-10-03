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
| `packages.*.agent-cli` | `agent run\|sweep\|shell` — dispatch via Apple `container` (macOS) or Docker, locally or on a remote Docker host via `--host`. |
| `lib.egressDomains` | The egress allowlist enforced by the Docker host's CONNECT proxy. |
| `lib.taskProfiles` | Task profiles: the environment variables each `--profile` requires. |
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

# Same, on a remote Docker host inside its egress-allowlisted network. The
# `dev` profile forwards the variables it names (here ANTHROPIC_API_KEY)
# from your environment, for example a `.env` file. Without GH_TOKEN, the
# launcher runs `$AGENT_GH_TOKEN_CMD owner/name` and uses the token it prints.
set -a; . ./.env; set +a
AGENT_GH_TOKEN_CMD=./mint-repo-token \
  agent run --host docker-host.example.internal --profile dev \
  --repo dryvist/some-repo "fix the flaky test in ci.yml"

# Fan the same task across every repo in a named group (lib.repoGroups),
# one disposable container per repo — each with its own repo-scoped token,
# just like `agent run --repo`. At most --concurrency run at once (default
# 4); an end-of-run table lists each repo, base branch, and PR URL or exit
# code. The group's profile is the default unless --profile overrides it.
AGENT_GH_TOKEN_CMD=./mint-repo-token \
  agent sweep --group nix --host docker-host.example.internal \
  "bump the flake.lock and open a PR"

# Debug shell inside the image (add --host to debug on the Docker host)
agent shell
```

The entrypoint refuses to start unless `AGENT_SANDBOX=1` (set only by the
image) and the uid is non-root. The autonomous configs are never rendered
onto a host filesystem by any code path.

## Safety model

- **Filesystem/process**: disposable container, non-root, `--rm`. On the
  docker runtime, runs are resource-capped (`--memory` / `--cpus` /
  `--pids-limit`), hardened (`--security-opt no-new-privileges`,
  `--cap-drop ALL`), and wall-clock-bounded (`AGENT_TIMEOUT`, default 3600s,
  then killed). Defaults live in `nix/agent-cli.nix`; each is env-overridable.
- **Secret egress**: before any push, the entrypoint runs `gitleaks` on the
  staged diff and aborts the commit/push (redacted output) on a finding.
- **Transcripts**: a `--host` run bind-mounts a per-run host spool dir onto each
  CLI's transcript subdir (`~/.claude/projects`, `~/.codex/sessions`,
  `~/.gemini/tmp`) under `/var/lib/agent-sandbox/spool/<run-id>/`, so the session
  records outlive `--rm`. A host-side log shipper can tail them; the host
  provisioning creates the spool root and prunes old runs. Only the transcript
  subdirs are mounted — never the state-home roots,
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
- **Network**: on a remote Docker host, containers join an internal-only
  Docker network whose sole route out is a CONNECT proxy allowlisting
  `lib.egressDomains`.
- **Secrets**: the container receives only the fixed credential list and the
  variables its `--profile` names, from the caller's environment (for example
  a `.env` file). `--repo` uses a repo-scoped `GH_TOKEN`, or the token that
  `AGENT_GH_TOKEN_CMD owner/name` prints.
- **Durability**: git. The branch/PR is the only thing that survives the run.
