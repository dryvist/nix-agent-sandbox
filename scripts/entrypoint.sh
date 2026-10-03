# Agent container entrypoint.
#
# Contract (all via environment):
#   AGENT_SANDBOX=1   set by the image itself; refusal guard below
#   AGENT_PROMPT      required (unless AGENT_SHELL=1): the task
#   AGENT_TOOL        claude | codex | gemini   (default: claude)
#   AGENT_REPO        optional owner/name to clone, branch, and PR against
#   AGENT_RUN_ID      optional stable run id (default: timestamp)
#   AGENT_SHELL=1     drop into bash instead of running an agent (debugging)
#   GH_TOKEN          scoped token for clone/push/PR when AGENT_REPO is set
#   AGENT_PROFILE     task profile from /home/agent/.agent-profiles.json;
#                     every variable it names must be set (the launcher
#                     forwards them from the caller's environment)
#
# This configuration is only safe inside a disposable container: the tools
# run with all approvals bypassed (see dryvist/nix-ai lib.renderAutonomous).

# --- Boundary guards -------------------------------------------------------
if [ "${AGENT_SANDBOX:-}" != "1" ]; then
  echo "agent-entrypoint: refusing to run: AGENT_SANDBOX=1 is not set." >&2
  echo "These configs bypass all tool approvals and must never run on a host." >&2
  exit 64
fi

if [ "$(id -u)" -eq 0 ]; then
  echo "agent-entrypoint: refusing to run as root (Claude rejects bypass mode as root; nothing here needs root)." >&2
  exit 64
fi

if [ "${AGENT_SHELL:-}" = "1" ]; then
  exec bash
fi

# Subscription-OAuth creds (agent-cli.sh inject_oauth_creds) land via
# `docker cp` before this entrypoint runs; tighten perms in case the copy
# didn't already chmod 600 (e.g. re-homed under a different tar impl).
for f in "${HOME}/.claude/.credentials.json" "${HOME}/.codex/auth.json" \
  "${HOME}/.gemini/oauth_creds.json" "${HOME}/.gemini/installation_id" \
  "${HOME}/.gemini/google_accounts.json"; do
  [ -e "$f" ] || continue
  chmod 600 "$f"
done

# --- Inputs ----------------------------------------------------------------
AGENT_TOOL="${AGENT_TOOL:-claude}"
AGENT_RUN_ID="${AGENT_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"

if [ -z "${AGENT_PROMPT:-}" ]; then
  echo "agent-entrypoint: AGENT_PROMPT is required (or AGENT_SHELL=1)." >&2
  exit 64
fi

workdir="${HOME}/work"
mkdir -p "${workdir}"
cd "${workdir}"

# --- Task profile: required environment ------------------------------------
# The profile names the variables this run needs; the launcher forwards them
# from the caller's environment. GH_TOKEN for --repo arrives the same way.
if [ -n "${AGENT_PROFILE:-}" ]; then
  profile="$(jq -ce --arg p "${AGENT_PROFILE}" '.[$p]' "${HOME}/.agent-profiles.json")" || {
    echo "agent-entrypoint: unknown AGENT_PROFILE '${AGENT_PROFILE}'." >&2
    exit 64
  }
  while IFS= read -r var; do
    [ -n "${!var:-}" ] || {
      echo "agent-entrypoint: AGENT_PROFILE '${AGENT_PROFILE}' requires ${var}." >&2
      exit 64
    }
  done < <(jq -r '.env[]' <<<"${profile}")
fi

# --- Workspace -------------------------------------------------------------
branch=""
if [ -n "${AGENT_REPO:-}" ]; then
  gh repo clone "${AGENT_REPO}" repo -- --depth 50
  cd repo
  branch="agent/${AGENT_TOOL}/${AGENT_RUN_ID}"
  git checkout -b "${branch}"
  git config user.name "${AGENT_GIT_NAME:-nix-agent-sandbox}"
  git config user.email "${AGENT_GIT_EMAIL:-agent@users.noreply.github.com}"
fi

# --- Run -------------------------------------------------------------------
status=0
case "${AGENT_TOOL}" in
  claude)
    claude -p --dangerously-skip-permissions "${AGENT_PROMPT}" || status=$?
    ;;
  codex)
    # approval_policy=never + sandbox_mode=danger-full-access come from the
    # baked config.toml; the container is the sandbox. --skip-git-repo-check
    # is required for a --repo-less run (cwd is $HOME/work, not a git repo);
    # harmless with AGENT_REPO set too, since that cwd is a real clone.
    codex exec --skip-git-repo-check "${AGENT_PROMPT}" || status=$?
    ;;
  gemini)
    gemini --approval-mode yolo -p "${AGENT_PROMPT}" || status=$?
    ;;
  *)
    echo "agent-entrypoint: unknown AGENT_TOOL '${AGENT_TOOL}' (claude|codex|gemini)" >&2
    exit 64
    ;;
esac

# --- Publish ---------------------------------------------------------------
# The branch/PR is the only durable output; the container is destroyed.
if [ -n "${branch}" ] && [ -n "$(git status --porcelain)" ]; then
  git add -A
  # Pre-push secret scan on exactly the staged diff (gitleaks is baked into
  # the image). Redacted output only. Any finding — or a scanner error /
  # missing binary (the `!` catches non-zero either way) — aborts before the
  # commit reaches origin. `git --staged` is the current form of the
  # deprecated `protect --staged`.
  if ! gitleaks git --staged --redact --no-banner; then
    echo "agent-entrypoint: gitleaks flagged the staged diff (or failed to run); refusing to commit/push." >&2
    exit 65
  fi
  git commit -m "feat(agent): autonomous ${AGENT_TOOL} run ${AGENT_RUN_ID}

Prompt: ${AGENT_PROMPT}

Assisted-by: ${AGENT_TOOL} (nix-agent-sandbox autonomous run)"
  git push -u origin "${branch}"
  gh pr create \
    --title "feat(agent): autonomous ${AGENT_TOOL} run ${AGENT_RUN_ID}" \
    --body "Autonomous run by nix-agent-sandbox.

- Tool: ${AGENT_TOOL}
- Run id: ${AGENT_RUN_ID}
- Exit status: ${status}

Prompt:

\`\`\`
${AGENT_PROMPT}
\`\`\`" \
    || echo "agent-entrypoint: PR creation failed; branch ${branch} was pushed." >&2
fi

exit "${status}"
