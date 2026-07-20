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
#                     requires BAO_ADDR + AppRole material below
#   BAO_ADDR          OpenBao API address; enables the profile secret fetch
#   BAO_ROLE_ID       AppRole role_id (ai-readonly / ai-apply-<svc> tier)
#   BAO_SECRET_ID     AppRole secret_id — or:
#   BAO_WRAPPED_SECRET_ID  single-use response-wrapping token holding the
#                     secret_id (the human-minted ai-apply grant path)
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

# --- OpenBao: task-profile secrets + per-run GitHub token ------------------
# The profile names a pre-defined group of secrets; whether this run's
# AppRole may actually read them is enforced server-side by its policies.
# AppRole material is consumed here and unset before any agent tool starts.
if [ -n "${AGENT_PROFILE:-}" ]; then
  if [ -z "${BAO_ADDR:-}" ]; then
    echo "agent-entrypoint: AGENT_PROFILE '${AGENT_PROFILE}' requires BAO_ADDR." >&2
    exit 64
  fi
  profile="$(jq -ce --arg p "${AGENT_PROFILE}" '.[$p]' "${HOME}/.agent-profiles.json")" || {
    echo "agent-entrypoint: unknown AGENT_PROFILE '${AGENT_PROFILE}'." >&2
    exit 64
  }

  if [ -n "${BAO_WRAPPED_SECRET_ID:-}" ]; then
    BAO_SECRET_ID="$(curl -fsS -X POST -H "X-Vault-Token: ${BAO_WRAPPED_SECRET_ID}" \
      "${BAO_ADDR}/v1/sys/wrapping/unwrap" | jq -re '.data.secret_id')" || {
      echo "agent-entrypoint: unwrapping the single-use secret_id failed (already used or expired?)." >&2
      exit 64
    }
  fi
  if [ -z "${BAO_ROLE_ID:-}" ]; then
    echo "agent-entrypoint: BAO_ROLE_ID is required with AGENT_PROFILE." >&2
    exit 64
  fi
  bao_token="$(jq -cn --arg r "${BAO_ROLE_ID}" --arg s "${BAO_SECRET_ID:-}" \
      '{role_id: $r, secret_id: $s}' \
    | curl -fsS -X POST -d @- "${BAO_ADDR}/v1/auth/approle/login" \
    | jq -re '.auth.client_token')" || {
    echo "agent-entrypoint: OpenBao AppRole login failed." >&2
    exit 64
  }
  unset BAO_ROLE_ID BAO_SECRET_ID BAO_WRAPPED_SECRET_ID

  # Export each profile KV field. The KV value wins over caller env: the
  # profile is the declared source of truth for what this run uses.
  while IFS=$'\t' read -r kv_path kv_field kv_env; do
    value="$(curl -fsS -H "X-Vault-Token: ${bao_token}" \
        "${BAO_ADDR}/v1/secret/data/${kv_path}" \
      | jq -re --arg f "${kv_field}" '.data.data[$f]')" || {
      echo "agent-entrypoint: secret/${kv_path}#${kv_field} unreadable (unseeded, or outside this AppRole's policy)." >&2
      exit 64
    }
    export "${kv_env}=${value}"
  done < <(jq -r '.kv[] | [.path, .field, .env] | @tsv' <<<"${profile}")

  # GitHub write access is NOT minted here. The container's AppRole
  # (ai-readonly / ai-apply-<svc>) only ever gets `github-mint`, which is
  # read-tier only by design (github-write is a separate, workstation-only
  # ambient identity) — this block is KV-fetch only; GH_TOKEN is whatever
  # the launcher already minted and passed in via -e (see agent-cli.sh).
  unset bao_token
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
