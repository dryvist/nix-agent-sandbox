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
| `packages.*.agent-dispatch` | `agent-dispatch` + `dispatch-ssh`: the job dispatcher for the sandbox Docker host ([below](#host-dispatcher)). |
| `packages.*.zcode-job` | ZCode-only SSH client with JSON output and an approved repository subset. |
| `homeManagerModules.zcode-job` | Optional client package and configuration for a restricted SSH alias and native Web/Server URL. |
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

## ZCode client

`zcode-job` submits batch work to the restricted dispatcher. Its configuration
contains the SSH alias, approved non-sensitive repository subset, and the SSO
URL of the always-on native Web/Server session. The Home Manager module is
disabled by default and requires an explicit repository list when enabled.

```sh
zcode-job repos
zcode-job start "$repo" "$prompt"
zcode-job status "$job_id"
zcode-job result "$job_id"
zcode-job continue "$job_id" "$message"
zcode-job cancel "$job_id"
zcode-job live
```

Every command prints JSON. `result` requires a terminal job and includes the
fixed six-line `job`, `tool`, `repo`, `state`, `pr`, and `duration` result.
`live` returns the configured SSO URL; `repos` returns the approved subset.
Unapproved start requests fail before SSH. Continuations and cancellations
check the existing job's tool and repository before sending a mutation.
The dispatcher independently checks its current repository access.

Requests contain the repository or job id and task text. Each SSH call has
a five-minute deadline. Exit 64 indicates invalid input or configuration;
exit 1 indicates an invalid response or unavailable result; transport failures
preserve the SSH or timeout exit code. Errors are JSON objects with `error`.

The shared `ai-delegation` plugin's `delegate-to-ai` skill owns content
eligibility and trusted verification of the returned draft PR.

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
# from your environment. Without GH_TOKEN, the launcher runs
# `$AGENT_GH_TOKEN_CMD owner/name` and uses the token it prints.
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

## Host dispatcher

`agent-dispatch` runs on the sandbox Docker host. A job is one disposable
container plus one named Docker volume, `agent-job-<id>`, mounted at
`/home/agent/work`. Each verb prints one JSON object.

```sh
agent-dispatch start [--interactive] <tool> <owner/repo> <prompt>
agent-dispatch continue <job-id> <message>
agent-dispatch status <job-id>
agent-dispatch cancel <job-id>
agent-dispatch refresh
```

- **Tools**: `zcode`, `opencode`, `cursor-agent`. Job ids are `j-` plus 16
  hex digits.
- **Output**: the container pushes `agent/<tool>/<job-id>` and opens a draft
  PR. The dispatcher records the PR URL only when it points at the job's repo.
- **`continue`** starts a new container on the same workspace and branch.
- **`cancel`** kills the container. **`refresh`** settles runs whose waiter
  has gone and removes finished jobs older than `AGENT_DISPATCH_RETENTION`.
- **`--interactive`** (zcode, opencode) serves the tool's web session on
  port 8080 inside the container. The container also joins the ingress
  network and carries Traefik labels for `https://<job-id>.<AGENT_DISPATCH_INGRESS_DOMAIN>`.
  `start` prints that address and a web token once.
- **Results**: each finished run posts a fixed six-line result (job, tool,
  repo, state, PR URL, duration) to a Vikunja project and an ntfy topic. No
  model output goes into it.

`dispatch-ssh` is the forced command for an `authorized_keys` entry. It
reads `SSH_ORIGINAL_COMMAND` and accepts only the five verbs. It passes each
word to `agent-dispatch` as its own argument, and the prompt is the rest of
the line. No shell evaluates the line, and `agent-dispatch` validates every
value: the tool allowlist, the `owner/repo` pattern, the job-id pattern and
the prompt (16 KiB, no control characters other than tab and newline).

### Credentials

Each `start` and `continue`:

1. logs in to OpenBao with an AppRole;
2. reads the `secret/apps/open-llm` bucket;
3. mints a GitHub token from `github-agents/token` for the job's repo only,
   with `contents` and `pull_requests` write;
4. checks that the token lists exactly that repo, and fails the job closed
   when it does not.

The container receives the GitHub token, the tool's model key and the prompt
as files copied in with `docker cp` before it starts. It never receives an
OpenBao address, AppRole material, a host path or the Docker socket. The
login token owns the lease behind the GitHub token. While the container runs,
the dispatcher renews the login token every half TTL. A failed renewal stops
the container and fails the job. The run ends as a timeout at
`AGENT_TIMEOUT` or at the token's max TTL, whichever comes first. The token
is revoked when the run ends.

### Environment

| Name | Use |
| --- | --- |
| `BAO_ADDR` | OpenBao address |
| `OPENBAO_APPROLE_OPEN_LLM_ROLE_ID`, `OPENBAO_APPROLE_OPEN_LLM_SECRET_ID` | AppRole login |
| `AGENT_DISPATCH_VIKUNJA_PROJECT` | Vikunja project id for results |
| `AGENT_DISPATCH_NTFY_TOPIC` | ntfy topic for results (default `ai-jobs`) |
| `AGENT_DISPATCH_INGRESS_DOMAIN` | parent domain of interactive sessions; required for `--interactive` |
| `AGENT_DISPATCH_INGRESS_NETWORK` | Docker network shared with the ingress proxy (default `agents-ingress`) |
| `AGENT_DISPATCH_INGRESS_MIDDLEWARES` | Traefik middlewares for the session route (optional) |
| `AGENT_DISPATCH_STATE_DIR` | job state (default `/var/lib/agent-dispatch`) |
| `AGENT_DISPATCH_RETENTION` | seconds a finished job is kept (default 86400) |
| `AGENT_IMAGE`, `AGENT_NETWORK`, `AGENT_PROXY_URL`, `AGENT_MEMORY`, `AGENT_CPUS`, `AGENT_PIDS_LIMIT`, `AGENT_TIMEOUT` | as for `agent` |

Bucket fields read: `GITHUB_AGENTS_INSTALLATION_ID`; each tool's task-profile
variables (`ZAI_SUBSCRIPTION_KEY`, `CURSOR_API_KEY`); `VIKUNJA_URL`,
`VIKUNJA_AI_JOBS_TOKEN`, `NTFY_URL` and `NTFY_AI_JOBS_TOKEN`. The host
provides `docker`, `curl` and `setsid`.

### Container inputs

| Input | Meaning |
| --- | --- |
| `AGENT_TOOL`, `AGENT_PROFILE`, `AGENT_REPO`, `AGENT_RUN_ID` | tool, its task profile, repo, job id |
| `AGENT_PR_DRAFT=1` | open the PR as a draft |
| `AGENT_CONTINUE=1` | a continued run on an existing workspace |
| `AGENT_INTERACTIVE=1`, `AGENT_PORT` | serve the web session on that port |
| `~/.agent-env` | `GH_TOKEN`, `GITHUB_TOKEN`, the profile's variables and, for `--interactive`, `AGENT_WEB_TOKEN` |
| `~/.agent-prompt` | the prompt or message |
| `~/work/.agent-pr-url` | written by the entrypoint after the tool exits; read by the dispatcher |

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
  variables its `--profile` names, from the caller's environment. `--repo`
  uses a repo-scoped `GH_TOKEN`, or the token that
  `AGENT_GH_TOKEN_CMD owner/name` prints.
- **Durability**: git. The branch/PR is the only thing that survives the run.
