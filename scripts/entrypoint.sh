# Agent container entrypoint.
#
# Contract (all via environment):
#   AGENT_SANDBOX=1   set by the image itself; refusal guard below
#   AGENT_PROMPT      required (unless AGENT_SHELL=1): the task
#   AGENT_TOOL        claude | codex | qwen | qwen-code | zcode | opencode | cursor-agent |
#                     zcode-web (default: claude)
#   AGENT_REPO        optional owner/name to clone, branch, and PR against
#   AGENT_RUN_ID      optional stable run id (default: timestamp)
#   AGENT_SHELL=1     drop into bash instead of running an agent (debugging)
#   GH_TOKEN          scoped token for clone/push/PR when AGENT_REPO is set
#   AGENT_PROFILE     task profile from /home/agent/.agent-profiles.json;
#                     every variable it names must be set (the launcher
#                     forwards them from the caller's environment)
#   AGENT_PR_DRAFT=1  open the PR as a draft
#   AGENT_TTY=1       run the tool's own interactive session on the attached
#                     terminal; no prompt
#   ~/.agent-env      optional NAME=value lines, exported (agent-dispatch)
#   ~/.agent-prompt   optional file that sets AGENT_PROMPT (agent-dispatch)
#   AGENT_SERVICE_ENV_FILE read-only ZCode service credentials file
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

AGENT_TOOL="${AGENT_TOOL:-claude}"
case "${AGENT_TOOL}" in
  qwen | qwen-code | zcode | opencode | cursor-agent)
    if [ -n "${AGENT_PROFILE:-}" ] && [ "${AGENT_PROFILE}" != "${AGENT_TOOL}" ]; then
      echo "agent-entrypoint: routed tool '${AGENT_TOOL}' requires its matching task profile." >&2
      exit 64
    fi
    AGENT_PROFILE="${AGENT_TOOL}"
    ;;
esac

if [ "${AGENT_SHELL:-}" = "1" ]; then
  exec bash
fi

# Subscription-OAuth creds (agent-cli.sh inject_oauth_creds) land via
# `docker cp` before this entrypoint runs; tighten perms in case the copy
# didn't already chmod 600 (e.g. re-homed under a different tar impl).
for f in "${HOME}/.claude/.credentials.json" "${HOME}/.codex/auth.json"; do
  [ -e "$f" ] || continue
  chmod 600 "$f"
done

# agent-dispatch copies a run's secrets and prompt in as files (`docker cp`),
# never as -e values. Each .agent-env line is NAME=value; the value is
# exported verbatim, never evaluated. Both files are read once and removed.
# Without them the run is unchanged.
agent_env_name_allowed() {
  local profile="${AGENT_PROFILE:-${AGENT_TOOL:-claude}}"
  case "$1" in
    GH_TOKEN | GITHUB_TOKEN | AGENT_ROUTER_BASE_URL | AGENT_ROUTER_KEY) return 0 ;;
  esac
  jq -e --arg profile "$profile" --arg name "$1" \
    '.[$profile].env | index($name) != null' \
    "${HOME}/.agent-profiles.json" >/dev/null 2>&1
}

if [ -f "${HOME}/.agent-env" ]; then
  env_file_error=0
  while IFS= read -r line || [ -n "${line}" ]; do
    [ -n "${line}" ] || continue
    case "${line}" in *=*) ;; *) env_file_error=1; continue ;; esac
    name="${line%%=*}"
    case "${name}" in '' | [0-9]* | *[!A-Za-z0-9_]*) env_file_error=1; continue ;; esac
    if ! agent_env_name_allowed "${name}"; then
      env_file_error=1
      continue
    fi
    declare -x -- "${name}=${line#*=}"
  done <"${HOME}/.agent-env"
  rm -f "${HOME}/.agent-env"
  if [ "${env_file_error}" -ne 0 ]; then
    echo "agent-entrypoint: unsupported value in .agent-env." >&2
    exit 64
  fi
fi
if [ -f "${HOME}/.agent-prompt" ]; then
  AGENT_PROMPT="$(cat "${HOME}/.agent-prompt")"
  rm -f "${HOME}/.agent-prompt"
fi

# --- Inputs ----------------------------------------------------------------
AGENT_TOOL="${AGENT_TOOL:-claude}"
AGENT_RUN_ID="${AGENT_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"

case "${AGENT_TOOL}" in
  qwen) AGENT_PROFILE="${AGENT_PROFILE:-qwen}" ;;
  qwen-code)
    AGENT_PROFILE="${AGENT_PROFILE:-qwen-code}"
    # The router's capability name: the only model this tool runs.
    AGENT_MODEL=medium
    ;;
  zcode) AGENT_PROFILE="${AGENT_PROFILE:-zcode}" ;;
  opencode) AGENT_PROFILE="${AGENT_PROFILE:-opencode}" ;;
  cursor-agent) AGENT_PROFILE="${AGENT_PROFILE:-cursor-agent}" ;;
  zcode-web)
    AGENT_PROFILE="${AGENT_PROFILE:-zcode-web}"
    service_env="${AGENT_SERVICE_ENV_FILE:-/run/agent-service.env}"
    [ -r "${service_env}" ] || {
      echo "agent-entrypoint: ZCode service credential file is not readable." >&2
      exit 64
    }
    seen_key=0
    seen_token=0
    while IFS= read -r line || [ -n "${line}" ]; do
      [ -n "${line}" ] || continue
      case "${line}" in *=*) ;; *) echo "agent-entrypoint: invalid ZCode service environment file." >&2; exit 64 ;; esac
      name="${line%%=*}"
      value="${line#*=}"
      case "${name}" in
        ZAI_SUBSCRIPTION_KEY)
          [ "${seen_key}" -eq 0 ] || { echo "agent-entrypoint: duplicate ZAI_SUBSCRIPTION_KEY." >&2; exit 64; }
          seen_key=1
          ZAI_SUBSCRIPTION_KEY="${value}"
          ;;
        AGENT_WEB_TOKEN)
          [ "${seen_token}" -eq 0 ] || { echo "agent-entrypoint: duplicate AGENT_WEB_TOKEN." >&2; exit 64; }
          seen_token=1
          AGENT_WEB_TOKEN="${value}"
          ;;
        *) echo "agent-entrypoint: unsupported name in ZCode service environment file." >&2; exit 64 ;;
      esac
    done <"${service_env}"
    export ZAI_SUBSCRIPTION_KEY AGENT_WEB_TOKEN
    ;;
esac

if [ -z "${AGENT_PROMPT:-}" ] && [ "${AGENT_TOOL}" != zcode-web ] && [ "${AGENT_TTY:-}" != 1 ]; then
  echo "agent-entrypoint: AGENT_PROMPT is required (or AGENT_SHELL=1)." >&2
  exit 64
fi

workdir="${HOME}/work"
mkdir -p "${workdir}"
cd "${workdir}" || exit

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
  done < <(jq -r --arg tty "${AGENT_TTY:-}" \
    'if $tty == "1" and .ttyLogin == true then [] else .env end | .[]' <<<"${profile}")
  if jq -e --arg tty "${AGENT_TTY:-}" \
    'has("routerKeyField") and (($tty == "1" and .ttyLogin == true) | not)' <<<"${profile}" >/dev/null; then
    for var in AGENT_ROUTER_BASE_URL AGENT_ROUTER_KEY; do
      [ -n "${!var:-}" ] || {
        echo "agent-entrypoint: AGENT_PROFILE '${AGENT_PROFILE}' requires ${var}." >&2
        exit 64
      }
    done
  fi
fi

# --- Workspace -------------------------------------------------------------
branch=""
base=""
if [ -n "${AGENT_REPO:-}" ]; then
  branch="agent/${AGENT_TOOL}/${AGENT_RUN_ID}"
  if [ -d repo/.git ]; then
    # A continued run (agent-dispatch `continue`) reuses its workspace clone.
    cd repo || exit
    git checkout "${branch}"
  else
    gh repo clone "${AGENT_REPO}" repo -- --depth 50
    cd repo || exit
    git checkout -b "${branch}"
    git config user.name "${AGENT_GIT_NAME:-nix-agent-sandbox}"
    git config user.email "${AGENT_GIT_EMAIL:-agent@users.noreply.github.com}"
  fi
  base="$(git rev-parse HEAD)"
fi

# --- Run -------------------------------------------------------------------
status=0
if [ "${AGENT_TTY:-}" = 1 ]; then
  case "${AGENT_TOOL}" in
    zcode | opencode | cursor-agent) "${AGENT_TOOL}" || status=$? ;;
    *)
      echo "agent-entrypoint: '${AGENT_TOOL}' has no terminal session" >&2
      exit 64
      ;;
  esac
else
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
  qwen | qwen-code)
    OPENAI_API_KEY="${AGENT_ROUTER_KEY}" qwen --auth-type openai --model "${AGENT_MODEL}" \
      --openai-base-url "${AGENT_ROUTER_BASE_URL}" --prompt "${AGENT_PROMPT}" --yolo || status=$?
    ;;
  zcode)
    zcode --prompt "${AGENT_PROMPT}" --mode yolo || status=$?
    ;;
  opencode)
    opencode run --auto "${AGENT_PROMPT}" || status=$?
    ;;
  cursor-agent)
    cursor-agent -p --force "${AGENT_PROMPT}" || status=$?
    ;;
  zcode-web)
    [ "${seen_key}" -eq 1 ] && [ "${seen_token}" -eq 1 ] &&
      [ -n "${ZAI_SUBSCRIPTION_KEY}" ] && [ -n "${AGENT_WEB_TOKEN}" ] || {
      echo "agent-entrypoint: ZCode service credentials must contain nonempty ZAI_SUBSCRIPTION_KEY and AGENT_WEB_TOKEN." >&2
      exit 64
    }
    export ZCODE_DATA_BASE_DIR="${ZCODE_DATA_BASE_DIR:-${HOME}/.zcode}"
    mkdir -p "${ZCODE_DATA_BASE_DIR}"
    ZAI_API_KEY="${ZAI_SUBSCRIPTION_KEY}" zcode-configure-key || exit $?
    export ZCODE_SERVER_AUTH_TOKEN="${AGENT_WEB_TOKEN}"
    export ZCODE_SERVER_HOST="${AGENT_SERVER_HOST:-0.0.0.0}"
    export PORT="${AGENT_PORT:-8080}"
    exec zcode-web-supervisor
    ;;
  *)
    echo "agent-entrypoint: unknown AGENT_TOOL '${AGENT_TOOL}' (claude|codex|qwen|qwen-code|zcode|opencode|cursor-agent|zcode-web)" >&2
    exit 64
    ;;
esac
fi

# --- Publish ---------------------------------------------------------------
# The branch/PR is the only durable output; the container is destroyed.
#
# Every branch requires signed commits, so the run's tree reaches origin as
# one commit created through the GitHub API (createCommitOnBranch), which
# GitHub signs for the job's App token. Local commits are never pushed.
# The mutation is all-or-nothing, and both limits are checked before anything
# reaches origin:
# ponytail: contents only. A change to a file mode or a symlink is refused,
# since the API would silently drop it; upgrade to the REST git-data API
# (blobs and a tree with modes) once its commits are confirmed signed.
# ponytail: one request carries the whole diff, capped at
# AGENT_PUBLISH_MAX_BYTES of encoded contents (default 8 MiB); upgrade to
# several chained commits if real runs need more.
signed_push() {
  local remote_head="" exists=0 created=0 tmp meta path old new kind query
  local max="${AGENT_PUBLISH_MAX_BYTES:-8388608}"
  if remote_head="$(git ls-remote --exit-code origin "refs/heads/${branch}" | cut -f1)"; then
    exists=1
    git fetch -q origin "${branch}"
  else
    remote_head="$(git rev-parse origin/HEAD)"
  fi
  tmp="$(mktemp -d)"
  : >"${tmp}/changes"
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    read -r old new _ _ kind <<<"${meta#:}"
    case "${old}:${new}" in
      100644:100644 | 000000:100644 | 100644:000000) ;;
      *)
        echo "agent-entrypoint: ${path} changes a file mode or symlink (${old} -> ${new}); the signed publish carries contents only." >&2
        rm -rf "${tmp}"
        return 1
        ;;
    esac
    if [ "${kind}" = D ]; then
      jq -cn --arg p "${path}" '{deletion: {path: $p}}'
    else
      base64 -w0 <"${path}" >"${tmp}/contents"
      jq -cn --arg p "${path}" --rawfile c "${tmp}/contents" '{addition: {path: $p, contents: $c}}'
    fi >>"${tmp}/changes"
  done < <(git diff -z --raw --no-renames "${remote_head}" HEAD)
  if [ ! -s "${tmp}/changes" ]; then
    rm -rf "${tmp}"
    return 0
  fi
  if [ "$(wc -c <"${tmp}/changes")" -gt "${max}" ]; then
    echo "agent-entrypoint: the change is larger than ${max} bytes encoded; nothing was published." >&2
    rm -rf "${tmp}"
    return 1
  fi
  query="mutation(\$input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: \$input) { commit { oid } } }"
  jq -s --arg q "${query}" --arg repo "${AGENT_REPO}" --arg br "${branch}" --arg oid "${remote_head}" \
    --arg h "feat(agent): ${AGENT_TOOL} run ${AGENT_RUN_ID}" \
    --arg b "$(git log --reverse --format='- %s' "${base}..HEAD")" \
    '{query: $q, variables: {input: {
      branch: {repositoryNameWithOwner: $repo, branchName: $br},
      message: {headline: $h, body: $b},
      expectedHeadOid: $oid,
      fileChanges: {additions: [.[].addition | select(.)], deletions: [.[].deletion | select(.)]}}}}' \
    "${tmp}/changes" >"${tmp}/request.json"
  if [ "${exists}" = 0 ]; then
    gh api "repos/${AGENT_REPO}/git/refs" -f "ref=refs/heads/${branch}" \
      -f "sha=${remote_head}" >/dev/null || {
      rm -rf "${tmp}"
      return 1
    }
    created=1
  fi
  if ! gh api graphql --input "${tmp}/request.json" --jq .data.createCommitOnBranch.commit.oid >/dev/null; then
    # No partial commit exists; drop a branch this run created.
    if [ "${created}" = 1 ]; then
      gh api -X DELETE "repos/${AGENT_REPO}/git/refs/heads/${branch}" >/dev/null 2>&1 || true
    fi
    rm -rf "${tmp}"
    return 1
  fi
  rm -rf "${tmp}"
}

# Only this step writes the PR URL file agent-dispatch reads, so anything the
# tool left at that path is removed first.
pr_file="${workdir}/.agent-pr-url"
rm -rf "${pr_file}"
draft=()
[ "${AGENT_PR_DRAFT:-}" != 1 ] || draft=(--draft)
if [ -n "${branch}" ] && [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "feat(agent): ${AGENT_TOOL} run ${AGENT_RUN_ID}

${AGENT_PROMPT:+Prompt: ${AGENT_PROMPT}

}Assisted-by: ${AGENT_TOOL} (nix-agent-sandbox)"
fi
# Commits the tool made itself are published too. Before publishing, gitleaks
# scans every new commit (redacted output). Any finding, or a scanner error
# or missing binary, aborts before anything reaches origin.
if [ -n "${branch}" ] && [ "$(git rev-parse HEAD)" != "${base}" ]; then
  if ! gitleaks git --log-opts="${base}..HEAD" --redact --no-banner; then
    echo "agent-entrypoint: gitleaks flagged the new commits (or failed to run); refusing to push." >&2
    exit 65
  fi
  if ! signed_push; then
    echo "agent-entrypoint: publishing ${branch} failed." >&2
    exit 1
  fi
  if url="$(gh pr create "${draft[@]}" --head "${branch}" \
    --title "feat(agent): autonomous ${AGENT_TOOL} run ${AGENT_RUN_ID}" \
    --body "Autonomous run by nix-agent-sandbox.

- Tool: ${AGENT_TOOL}
- Run id: ${AGENT_RUN_ID}
- Exit status: ${status}

Prompt:

\`\`\`
${AGENT_PROMPT:-}
\`\`\`")"; then
    printf '%s\n' "${url}" | tee "${pr_file}"
  elif url="$(gh pr view "${branch}" --json url --jq .url)"; then
    # A continued run pushes to the branch of the PR it already opened.
    printf '%s\n' "${url}" | tee "${pr_file}"
  else
    echo "agent-entrypoint: PR creation failed; branch ${branch} was published." >&2
  fi
fi

exit "${status}"
