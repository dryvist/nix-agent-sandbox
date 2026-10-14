#!/usr/bin/env bash
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

set +x
umask 077

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
  qwen | qwen-code | zcode | opencode | opencode-local | opencode-zai | shell | cursor-agent)
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
    GH_TOKEN | GITHUB_TOKEN | AGENT_ROUTER_BASE_URL | AGENT_ROUTER_KEY | BAO_ADDR | \
      SANDBOX_ROLE_ID | SANDBOX_WRAPPED_SECRET_ID | GIT_MIRROR_URL | VIKUNJA_URL | ZAMMAD_URL) return 0 ;;
  esac
  jq -e --arg profile "$profile" --arg name "$1" \
    '.[$profile].env | index($name) != null' \
    "${HOME}/.agent-profiles.json" >/dev/null 2>&1
}

if [ -f "${HOME}/.agent-env" ]; then
  chmod 600 "${HOME}/.agent-env"
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
AGENT_MODE="${AGENT_MODE:-start}"

case "${AGENT_MODE}" in
  start) ;;
  fix)
    [ -n "${AGENT_REPO:-}" ] && [ -n "${AGENT_BRANCH:-}" ] && [ -n "${AGENT_EXPECTED_SHA:-}" ] || {
      echo "agent-entrypoint: fix mode requires AGENT_REPO, AGENT_BRANCH and AGENT_EXPECTED_SHA." >&2
      exit 64
    }
    [[ ${AGENT_EXPECTED_SHA} =~ ^[0-9a-f]{40}$ ]] || {
      echo "agent-entrypoint: invalid AGENT_EXPECTED_SHA." >&2
      exit 64
    }
    ;;
  *)
    echo "agent-entrypoint: unknown AGENT_MODE '${AGENT_MODE}'." >&2
    exit 64
    ;;
esac

case "${AGENT_TOOL}" in
  qwen) AGENT_PROFILE="${AGENT_PROFILE:-qwen}" ;;
  qwen-code)
    AGENT_PROFILE="${AGENT_PROFILE:-qwen-code}"
    # The router's capability name: the only model this tool runs.
    AGENT_MODEL=medium
    ;;
  zcode) AGENT_PROFILE="${AGENT_PROFILE:-zcode}" ;;
  opencode) AGENT_PROFILE="${AGENT_PROFILE:-opencode}" ;;
  opencode-local) AGENT_PROFILE="${AGENT_PROFILE:-opencode-local}" ;;
  opencode-zai) AGENT_PROFILE="${AGENT_PROFILE:-opencode-zai}" ;;
  shell)
    AGENT_PROFILE="${AGENT_PROFILE:-shell}"
    [ "${AGENT_MODE}" = fix ] || {
      echo "agent-entrypoint: the shell tool runs only in fix mode." >&2
      exit 64
    }
    ;;
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

openbao_child="${AGENT_OPENBAO_CHILD:-}"
export -n openbao_child
openbao_agent_dir="${AGENT_OPENBAO_AUTH_DIR:-/dev/shm/agent-openbao}"
unset AGENT_OPENBAO_AUTH_DIR
if [ "${openbao_child}" != 1 ] && \
  { [ "${AGENT_DISPATCHED_JOB:-}" = 1 ] || [ -n "${SANDBOX_ROLE_ID:-}${SANDBOX_WRAPPED_SECRET_ID:-}" ]; }; then
  mkdir -p "${openbao_agent_dir}" && chmod 700 "${openbao_agent_dir}"
  printf '%s' "${SANDBOX_ROLE_ID:-}" >"${openbao_agent_dir}/role-id"
  printf '%s' "${SANDBOX_WRAPPED_SECRET_ID:-}" >"${openbao_agent_dir}/wrapped-secret-id"
  chmod 600 "${openbao_agent_dir}/role-id" "${openbao_agent_dir}/wrapped-secret-id"
  unset SANDBOX_ROLE_ID SANDBOX_WRAPPED_SECRET_ID AGENT_ROUTER_KEY VIKUNJA_API_TOKEN ZAMMAD_HTTP_TOKEN

  profile_key="$(jq -r --arg p "${AGENT_PROFILE:-$AGENT_TOOL}" --arg tty "${AGENT_TTY:-}" \
    'if $tty == "1" and .[$p].ttyLogin == true then "" else .[$p].sandboxRouterKeyField // "" end' \
    "${HOME}/.agent-profiles.json")"
  export AGENT_SANDBOX_ROUTER_KEY_FIELD="${profile_key}"
  export AGENT_OPENBAO_CHILD=1

  if [ "${AGENT_MODE:-start}" = fix ]; then
    openbao_agent_config=/etc/openbao-agent/read.hcl
  else
    openbao_agent_config=/etc/openbao-agent/write.hcl
  fi
  agent_status=0
  bao agent -config="${openbao_agent_config}" || agent_status=$?
  rm -f "${openbao_agent_dir}/role-id" "${openbao_agent_dir}/wrapped-secret-id"
  exit "${agent_status}"
fi
unset AGENT_OPENBAO_CHILD AGENT_SANDBOX_ROUTER_KEY_FIELD

configure_sandbox_mcp() {
  local config_path config_content
  case "${AGENT_TOOL}" in
    zcode) config_path="${HOME}/.zcode/cli/config.json"; config_content="${ZCODE_MCP_CONFIG}" ;;
    qwen-code) config_path="${HOME}/.qwen/settings.json"; config_content="${QWEN_MCP_CONFIG}" ;;
    *) return 0 ;;
  esac
  mkdir -p "${config_path%/*}"
  chmod 700 "${config_path%/*}"
  printf '%s\n' "${config_content}" >"${config_path}"
  chmod 600 "${config_path}"
}

trap '
  rm -f "${openbao_agent_dir}/role-id" "${openbao_agent_dir}/wrapped-secret-id"
  if [ "${AGENT_DISPATCHED_JOB:-}" = 1 ]; then
    case "${AGENT_TOOL:-}" in
      zcode) rm -f "${HOME}/.zcode/cli/config.json" "${HOME}/.zcode/v2/provider_config.json" ;;
      qwen-code) rm -f "${HOME}/.qwen/settings.json" ;;
    esac
  fi
  unset AGENT_ROUTER_KEY ZAI_SUBSCRIPTION_KEY VIKUNJA_API_TOKEN ZAMMAD_HTTP_TOKEN \
    SANDBOX_ROLE_ID SANDBOX_WRAPPED_SECRET_ID AGENT_SANDBOX_ROUTER_KEY_FIELD
' EXIT
if [ "${openbao_child:-}" = 1 ]; then
  configure_sandbox_mcp
fi
unset openbao_child

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
  if [ "${AGENT_MODE}" = fix ]; then
    branch="${AGENT_BRANCH}"
    rm -rf "${workdir}/.agent-fix"
    repo_url="https://github.com/${AGENT_REPO}"
    if git ls-remote --exit-code "${repo_url}" "refs/heads/${AGENT_BRANCH}" >/dev/null 2>&1; then
      git clone --depth 50 --branch "${AGENT_BRANCH}" "${repo_url}" repo
      cd repo || exit
    else
      git clone --depth 50 "${repo_url}" repo
      cd repo || exit
      if ! git cat-file -e "${AGENT_EXPECTED_SHA}^{commit}" 2>/dev/null; then
        git fetch --depth=1 origin "${AGENT_EXPECTED_SHA}" || {
          echo "agent-entrypoint: head moved; expected commit is no longer available." >&2
          exit 66
        }
      fi
      git checkout --detach "${AGENT_EXPECTED_SHA}"
    fi
    if [ "$(git rev-parse HEAD)" != "${AGENT_EXPECTED_SHA}" ]; then
      echo "agent-entrypoint: head moved; branch does not match AGENT_EXPECTED_SHA." >&2
      exit 66
    fi
    git config user.name "${AGENT_GIT_NAME:-nix-agent-sandbox}"
    git config user.email "${AGENT_GIT_EMAIL:-agent@users.noreply.github.com}"
    base="${AGENT_EXPECTED_SHA}"
  elif [ -d repo/.git ]; then
    branch="agent/${AGENT_TOOL}/${AGENT_RUN_ID}"
    # A continued run (agent-dispatch `continue`) reuses its workspace clone.
    cd repo || exit
    git checkout "${branch}"
  else
    branch="agent/${AGENT_TOOL}/${AGENT_RUN_ID}"
    gh repo clone "${AGENT_REPO}" repo -- --depth 50
    cd repo || exit
    git checkout -b "${branch}"
    git config user.name "${AGENT_GIT_NAME:-nix-agent-sandbox}"
    git config user.email "${AGENT_GIT_EMAIL:-agent@users.noreply.github.com}"
  fi
  base="$(git rev-parse HEAD)"
fi

make_fix_outputs() {
  local tmp outdir meta path old new kind size subject=""
  local max="${AGENT_PUBLISH_MAX_BYTES:-8388608}"
  FIX_NO_CHANGE=0
  tmp=$(mktemp -d)
  outdir="${workdir}/.agent-fix"
  rm -rf "${outdir}"
  [[ ${max} =~ ^[0-9]+$ ]] || {
    echo "agent-entrypoint: invalid AGENT_PUBLISH_MAX_BYTES." >&2
    rm -rf "${tmp}"
    return 1
  }
  git add -A || { rm -rf "${tmp}"; return 1; }
  if [ "$(git rev-parse HEAD)" != "${AGENT_EXPECTED_SHA}" ]; then
    subject=$(git log -1 --format=%s)
    subject=${subject:0:100}
  fi
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
  done < <(git diff --cached -z --raw --no-renames "${AGENT_EXPECTED_SHA}")
  if [ ! -s "${tmp}/changes" ]; then
    rm -rf "${tmp}"
    rm -rf "${outdir}"
    FIX_NO_CHANGE=1
    return 0
  fi
  size=$(wc -c <"${tmp}/changes")
  if [ "${size}" -gt "${max}" ]; then
    echo "agent-entrypoint: the change is larger than ${max} bytes encoded; nothing was published." >&2
    rm -rf "${tmp}"
    return 1
  fi
  jq -s '{additions: [.[].addition | select(.)], deletions: [.[].deletion | select(.)]}' \
    "${tmp}/changes" >"${tmp}/changes.json"
  if ! git diff --cached --quiet HEAD; then
    git -c user.name="${AGENT_GIT_NAME:-nix-agent-sandbox}" \
      -c user.email="${AGENT_GIT_EMAIL:-agent@users.noreply.github.com}" \
      commit -m "CI resolver change" >/dev/null || { rm -rf "${tmp}"; return 1; }
  fi
  if ! gitleaks git --log-opts="${AGENT_EXPECTED_SHA}..HEAD" --redact --no-banner; then
    echo "agent-entrypoint: gitleaks flagged the fix change (or failed to run); refusing to publish." >&2
    rm -rf "${tmp}"
    exit 65
  fi
  mkdir -p "${outdir}"
  mv "${tmp}/changes.json" "${outdir}/changes.json"
  git diff --binary --cached "${AGENT_EXPECTED_SHA}" >"${outdir}/patch.diff"
  if [ -n "${subject}" ]; then printf '%s\n' "${subject}" >"${outdir}/summary.txt"; else : >"${outdir}/summary.txt"; fi
  rm -rf "${tmp}"
}

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
    qwen_router_key=${AGENT_ROUTER_KEY}
    unset AGENT_ROUTER_KEY
    OPENAI_API_KEY="${qwen_router_key}" qwen --auth-type openai --model "${AGENT_MODEL}" \
      --openai-base-url "${AGENT_ROUTER_BASE_URL}" --prompt "${AGENT_PROMPT}" --yolo || status=$?
    unset qwen_router_key
    ;;
  zcode)
    if [ -n "${AGENT_ROUTER_BASE_URL:-}" ] && [ -n "${AGENT_ROUTER_KEY:-}" ]; then
      personal_provider_config="${ZCODE_DATA_BASE_DIR:-${HOME}}/.zcode/v2/provider_config.json"
      mkdir -p "${personal_provider_config%/*}"
      # ZCode v2 provider_config.json schema is defined in nix-ai's
      # packages/provider-node/src/provider-config-file-codec.ts and
      # packages/provider/src/config/{provider-data-schema,rule-data-schema}.ts.
      AGENT_ROUTER_BASE_URL="$AGENT_ROUTER_BASE_URL" AGENT_ROUTER_KEY="$AGENT_ROUTER_KEY" \
        jq -n \
        '{schemaVersion: 1, config: {
          providerOrder: ["agent-router"],
          providerConfigRules: {providerRules: [{
            providerId: "agent-router", providerName: "Agent Router", enabled: true,
            config: {
              group: "standard-personal",
              access: {type: "api-key", apiKey: env.AGENT_ROUTER_KEY},
              api: {type: "openai-chat-completions", baseUrl: env.AGENT_ROUTER_BASE_URL},
              personalModelIds: ["medium"]
            }
          }]},
          modelConfigRules: {providerModelRules: [], manualProviderModelRules: []},
          defaultModelSelection: {providerId: "agent-router", modelId: "medium"}
        }}' >"${personal_provider_config}"
      chmod 600 "${personal_provider_config}"
      export ZCODE_PERSONAL_PROVIDER_CONFIG_FILE="${personal_provider_config}"
    fi
    unset AGENT_ROUTER_KEY
    zcode --prompt "${AGENT_PROMPT}" --mode yolo || status=$?
    ;;
  opencode | opencode-local)
    if [ -n "${AGENT_ROUTER_BASE_URL:-}" ] && [ -n "${AGENT_ROUTER_KEY:-}" ]; then
      opencode_config="${HOME}/.config/opencode/opencode.json"
      mkdir -p "${opencode_config%/*}"
      AGENT_ROUTER_BASE_URL="$AGENT_ROUTER_BASE_URL" AGENT_ROUTER_KEY="$AGENT_ROUTER_KEY" \
        jq -n \
        '{provider: {"agent-router": {
          npm: "@ai-sdk/openai-compatible",
          name: "Agent Router",
          options: {baseURL: env.AGENT_ROUTER_BASE_URL, apiKey: env.AGENT_ROUTER_KEY},
          models: {medium: {name: "medium"}}
        }}}' >"${opencode_config}"
      chmod 600 "${opencode_config}"
      export OPENCODE_CONFIG="${opencode_config}"
    fi
    opencode run --auto --model agent-router/medium "${AGENT_PROMPT}" || status=$?
    unset AGENT_ROUTER_KEY
    ;;
  shell)
    bash -euo pipefail -c "${AGENT_PROMPT}" || status=$?
    ;;
  opencode-zai)
    zai_subscription_key=${ZAI_SUBSCRIPTION_KEY}
    unset ZAI_SUBSCRIPTION_KEY
    ZHIPU_API_KEY="${zai_subscription_key}" opencode run --auto \
      --model zai-coding-plan/glm-5.3 "${AGENT_PROMPT}" || status=$?
    unset zai_subscription_key
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
    echo "agent-entrypoint: unknown AGENT_TOOL '${AGENT_TOOL}' (claude|codex|qwen|qwen-code|zcode|opencode|opencode-local|opencode-zai|shell|cursor-agent|zcode-web)" >&2
    exit 64
    ;;
esac
fi

if [ "${AGENT_MODE}" = fix ]; then
  make_fix_outputs || exit $?
  if [ "${FIX_NO_CHANGE:-}" = 1 ]; then exit 0; fi
  exit "${status}"
fi

if [ "${status}" -ne 0 ]; then
  echo "agent-entrypoint: ${AGENT_TOOL} exited with status ${status}; refusing to publish." >&2
  exit "${status}"
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
