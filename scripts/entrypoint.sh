#!/usr/bin/env bash
# Agent container entrypoint.
#
# Contract (all via environment):
#   AGENT_SANDBOX=1   set by the image itself; refusal guard below
#   AGENT_PROMPT      required (unless AGENT_SHELL=1): the task
#   AGENT_TOOL        claude | codex | qwen | qwen-code | zcode | opencode | cursor-agent |
#                     zcode-web (default: claude)
#   AGENT_REPO        optional owner/name to clone, branch, and PR against
#   GIT_MIRROR_URL    public mirror URL for a repo-less zcode terminal
#   AGENT_RUN_ID      stable run id; required for opencode, otherwise optional (default: timestamp)
#   AGENT_SHELL=1     drop into bash instead of running an agent (debugging)
#   GH_TOKEN          scoped token for clone/push/PR when AGENT_REPO is set
#   AGENT_PROFILE     task profile from /home/agent/.agent-profiles.json;
#                     every variable it names must be set (the launcher
#                     forwards them from the caller's environment)
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

# Z.ai models come only from OpenBao ZAI_MODEL (secrets-external/ai/saas/zai);
# the router never lists GLM, so there is no fallback.
require_zai_model() {
  [ -n "${ZAI_MODEL:-}" ] || {
    echo "agent-entrypoint: ZAI_MODEL is missing; set it in OpenBao secrets-external/ai/saas/zai." >&2
    exit 65
  }
  zai_model=${ZAI_MODEL}
  unset ZAI_MODEL
}

require_cursor_api_key() {
  [ -n "${CURSOR_API_KEY:-}" ] || {
    echo "agent-entrypoint: CURSOR_API_KEY is missing; set it in OpenBao secrets-external/data/ai/saas/cursor." >&2
    exit 65
  }
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
  export AGENT_PROMPT
  rm -f "${HOME}/.agent-prompt"
fi

# --- Inputs ----------------------------------------------------------------
AGENT_TOOL="${AGENT_TOOL:-claude}"
if [ "${AGENT_TOOL}" = opencode ] && [ -z "${AGENT_RUN_ID:-}" ]; then
  echo "agent-entrypoint: OpenCode requires AGENT_RUN_ID." >&2
  exit 64
fi
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
profile_tracker_access() {
  local p profile_json
  p="${AGENT_PROFILE:-$AGENT_TOOL}"
  if ! profile_json=$(jq -ce --arg p "$p" '.[$p]' "${HOME}/.agent-profiles.json"); then
    echo "agent-entrypoint: unknown AGENT_PROFILE '${p}'." >&2
    return 64
  fi
  if ! jq -e 'type == "object" and
    (if has("trackerAccess") then (.trackerAccess | type == "boolean") else true end)' \
    <<<"${profile_json}" >/dev/null; then
    echo "agent-entrypoint: AGENT_PROFILE '${p}' trackerAccess must be boolean." >&2
    return 64
  fi
  jq -r 'if has("trackerAccess") then .trackerAccess else true end' <<<"${profile_json}"
}
if [ "${openbao_child}" != 1 ] && \
  { [ "${AGENT_DISPATCHED_JOB:-}" = 1 ] || [ -n "${SANDBOX_ROLE_ID:-}${SANDBOX_WRAPPED_SECRET_ID:-}" ]; }; then
  tracker_access=$(profile_tracker_access) || exit $?
  profile_tracker="${tracker_access}"
  if [ "${AGENT_TTY:-}" = 1 ] && \
    jq -e --arg p "${AGENT_PROFILE:-$AGENT_TOOL}" \
      '.[$p].ttyLogin == true' "${HOME}/.agent-profiles.json" >/dev/null 2>&1; then
    tracker_access=true
  fi
  mkdir -p "${openbao_agent_dir}" && chmod 700 "${openbao_agent_dir}"
  printf '%s' "${SANDBOX_ROLE_ID:-}" >"${openbao_agent_dir}/role-id"
  printf '%s' "${SANDBOX_WRAPPED_SECRET_ID:-}" >"${openbao_agent_dir}/wrapped-secret-id"
  chmod 600 "${openbao_agent_dir}/role-id" "${openbao_agent_dir}/wrapped-secret-id"
  unset SANDBOX_ROLE_ID SANDBOX_WRAPPED_SECRET_ID AGENT_ROUTER_KEY VIKUNJA_API_TOKEN ZAMMAD_HTTP_TOKEN

  # The selected profile owns this field so OpenCode variants can use separate leaves.
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
  case "${AGENT_TOOL}" in
    zcode) openbao_agent_config="${openbao_agent_config%.hcl}-zcode.hcl" ;;
    opencode | opencode-local) openbao_agent_config="${openbao_agent_config%.hcl}-opencode.hcl" ;;
    *)
      if [ "${tracker_access}" = false ]; then
        openbao_agent_config="${openbao_agent_config%.hcl}-public.hcl"
      fi
      ;;
  esac
  agent_status=0
  AGENT_TRACKER_ACCESS="${profile_tracker}" bao agent -config="${openbao_agent_config}" || agent_status=$?
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
  unset AGENT_ROUTER_KEY ZAI_SUBSCRIPTION_KEY ZAI_API_KEY ZAI_MODEL CURSOR_API_KEY VIKUNJA_API_TOKEN ZAMMAD_HTTP_TOKEN \
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

if [ "${AGENT_PUBLIC_MIRROR:-}" = 1 ] && [ -z "${AGENT_REPO:-}" ] && \
  [ "${AGENT_TOOL}" = zcode ] && [ "${AGENT_TTY:-}" = 1 ]; then
  mirror_url="${GIT_MIRROR_URL:-}"
  mirror_url="${mirror_url%/}"
  case "$mirror_url" in
    http://* | https://*) ;;
    *) echo "agent-entrypoint: repo-less zcode requires a public GIT_MIRROR_URL." >&2; exit 64 ;;
  esac
  case "$mirror_url" in
    */public) ;;
    *) echo "agent-entrypoint: repo-less zcode only accepts the public mirror tree." >&2; exit 64 ;;
  esac
  case "$mirror_url" in
    *[[:space:]]*) echo "agent-entrypoint: invalid GIT_MIRROR_URL." >&2; exit 64 ;;
  esac
  mirror_readme="Public mirror repositories: \${GIT_MIRROR_URL}/<owner>/<repo>."
  if [ ! -f README.md ]; then
    printf '%s\n' "$mirror_readme" >README.md || {
      echo "agent-entrypoint: repo-less workspace README is missing." >&2
      exit 64
    }
  fi
  [ "$(cat README.md)" = "$mirror_readme" ] || {
    echo "agent-entrypoint: repo-less workspace README is invalid." >&2
    exit 64
  }
  git config --global "url.${mirror_url}/.insteadOf" "https://github.com/"
  git config --global --add "url.${mirror_url}/.insteadOf" "git@github.com:"
fi

# --- Task profile: required environment ------------------------------------
# The profile names the variables this run needs; the launcher forwards them
# from the caller's environment. GH_TOKEN for --repo arrives the same way.
if [ -n "${AGENT_PROFILE:-}" ]; then
  profile="$(jq -ce --arg p "${AGENT_PROFILE}" '.[$p]' "${HOME}/.agent-profiles.json")" || {
    echo "agent-entrypoint: unknown AGENT_PROFILE '${AGENT_PROFILE}'." >&2
    exit 64
  }
  if ! jq -e 'type == "object" and
    (if has("trackerAccess") then (.trackerAccess | type == "boolean") else true end)' \
    <<<"${profile}" >/dev/null; then
    echo "agent-entrypoint: AGENT_PROFILE '${AGENT_PROFILE}' trackerAccess must be boolean." >&2
    exit 64
  fi
  while IFS= read -r var; do
    # Provider key checks below fail closed with their provider-specific path.
    case "${var}" in ZAI_MODEL | CURSOR_API_KEY) continue ;; esac
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
    if ! git fetch origin; then
      echo "agent-entrypoint: failed to fetch origin before creating run branch." >&2
      exit 1
    fi
    # Review jobs reach a pull request head by name (origin/pr/N); a failed
    # fetch only logs and the run continues.
    if ! git fetch origin '+refs/pull/*/head:refs/remotes/origin/pr/*'; then
      echo "agent-entrypoint: failed to fetch pull request heads; continuing without origin/pr refs." >&2
    fi
    if ! git remote set-head origin --auto; then
      echo "agent-entrypoint: failed to set origin/HEAD before creating run branch." >&2
      exit 1
    fi
    git checkout --no-track -b "${branch}" origin/HEAD
    git config user.name "${AGENT_GIT_NAME:-nix-agent-sandbox}"
    git config user.email "${AGENT_GIT_EMAIL:-agent@users.noreply.github.com}"
  fi
  base="$(git rev-parse HEAD)"
fi

# One classifier for both publish paths: writes one JSON line per change
# between $1 and the index ("cached") or $3 (a commit) to file $2. An
# addition carries path, git mode (100644 or 100755) and base64 contents; a
# deletion carries path and "delete": true. Nothing here touches the network.
collect_changes() {
  local from=$1 out=$2 target=$3 meta path old new kind
  local -a range=()
  if [ "${target}" = cached ]; then
    range=(-z --raw --no-renames --cached "${from}")
  else
    range=(-z --raw --no-renames "${from}" "${target}")
  fi
  : >"${out}"
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    read -r old new _ _ kind <<<"${meta#:}"
    case "${path}" in
      .github/workflows/*)
        echo "agent-entrypoint: ${path} is a workflow file; the sandbox token has no workflows permission, so nothing was published." >&2
        return 1
        ;;
    esac
    case "${old}:${new}" in
      120000:*)
        echo "agent-entrypoint: ${path} deletes or replaces a symlink (${old} -> ${new}); the publish cannot carry symlinks." >&2
        return 1
        ;;
      *:120000)
        echo "agent-entrypoint: ${path} adds a symlink (${old} -> ${new}); the publish cannot carry symlinks." >&2
        return 1
        ;;
      160000:*)
        echo "agent-entrypoint: ${path} deletes or replaces a submodule (${old} -> ${new}); the publish cannot carry submodules." >&2
        return 1
        ;;
      *:160000)
        echo "agent-entrypoint: ${path} adds a submodule (${old} -> ${new}); the publish cannot carry submodules." >&2
        return 1
        ;;
      100644:100755 | 100755:100644)
        echo "agent-entrypoint: ${path} changes the file mode (${old} -> ${new}); the publish refuses a real mode change." >&2
        return 1
        ;;
      100644:100644 | 100755:100755 | 000000:100644 | 000000:100755 | 100644:000000 | 100755:000000) ;;
      *)
        echo "agent-entrypoint: ${path} has an unsupported file type (${old} -> ${new}); nothing was published." >&2
        return 1
        ;;
    esac
    if [ "${kind}" = D ]; then
      jq -cn --arg p "${path}" '{path: $p, delete: true}'
    else
      base64 -w0 <"${path}" >"${out}.b64"
      jq -cn --arg p "${path}" --arg m "${new}" --rawfile c "${out}.b64" \
        '{path: $p, mode: $m, contents: $c}'
    fi >>"${out}"
  done < <(git diff "${range[@]}")
  rm -f "${out}.b64"
}

make_fix_outputs() {
  local tmp outdir path size subject=""
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
  if ! collect_changes "${AGENT_EXPECTED_SHA}" "${tmp}/changes" cached; then
    rm -rf "${tmp}"
    return 1
  fi
  # The dispatcher publishes these changes with createCommitOnBranch, which
  # carries contents only, so an executable change has nowhere to keep its
  # bit; only the start-mode publish can carry one.
  while IFS= read -r path; do
    echo "agent-entrypoint: ${path} is executable; the fix publish cannot keep the executable bit, so nothing was published." >&2
    rm -rf "${tmp}"
    return 1
  done < <(jq -r 'select(.mode == "100755") | .path' "${tmp}/changes")
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
  jq -s '{additions: [.[] | select(has("contents")) | {path, contents}],
    deletions: [.[] | select(.delete) | {path}]}' \
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
tool_stderr="$(mktemp)" || {
  echo "agent-entrypoint: could not create the tool stderr file." >&2
  exit 1
}
case "${AGENT_TOOL}" in
  claude)
    claude -p --dangerously-skip-permissions "${AGENT_PROMPT}" 2>"${tool_stderr}" || status=$?
    ;;
  codex)
    # approval_policy=never + sandbox_mode=danger-full-access come from the
    # baked config.toml; the container is the sandbox. --skip-git-repo-check
    # is required for a --repo-less run (cwd is $HOME/work, not a git repo);
    # harmless with AGENT_REPO set too, since that cwd is a real clone.
    codex_output_dir="${HOME}/.codex/sessions"
    mkdir -p "${codex_output_dir}" || {
      echo "agent-entrypoint: could not create the Codex output directory." >&2
      exit 1
    }
    codex_output_file="$(mktemp "${codex_output_dir}/last-message.XXXXXX")" || {
      echo "agent-entrypoint: could not create the Codex output file." >&2
      exit 1
    }
    codex exec --skip-git-repo-check -o "${codex_output_file}" "${AGENT_PROMPT}" </dev/null || {
      status=$?
      echo "agent-entrypoint: codex exited with status ${status}; refusing to publish." >&2
      exit "${status}"
    }
    if [ ! -s "${codex_output_file}" ]; then
      echo "agent-entrypoint: codex returned an empty final message; refusing to publish." >&2
      exit 1
    fi
    cat "${codex_output_file}"
    ;;
  qwen | qwen-code)
    qwen_router_key=${AGENT_ROUTER_KEY}
    unset AGENT_ROUTER_KEY
    OPENAI_API_KEY="${qwen_router_key}" qwen --auth-type openai --model "${AGENT_MODEL}" \
      --openai-base-url "${AGENT_ROUTER_BASE_URL}" --prompt "${AGENT_PROMPT}" --yolo 2>"${tool_stderr}" || status=$?
    unset qwen_router_key
    ;;
  zcode)
    [ -n "${ZAI_API_KEY:-}" ] || {
      echo "agent-entrypoint: zcode needs ZAI_API_KEY." >&2
      exit 64
    }
    export ZCODE_DATA_BASE_DIR="${ZCODE_DATA_BASE_DIR:-${HOME}/.zcode}"
    mkdir -p "${ZCODE_DATA_BASE_DIR}"
    require_zai_model
    ZAI_MODEL="${zai_model}" ZAI_API_KEY="${ZAI_API_KEY}" zcode-configure-key || exit $?
    unset ZAI_API_KEY ZAI_MODEL
    zcode --prompt "${AGENT_PROMPT}" --mode yolo 2>"${tool_stderr}" || status=$?
    ;;
  opencode | opencode-local)
    # The selected profile supplies the key; OpenCode uses a listed Go model and local uses medium.
    if [ "${AGENT_TOOL}" = opencode ]; then
      if [ -z "${AGENT_ROUTER_BASE_URL:-}" ] || [ -z "${AGENT_ROUTER_KEY:-}" ]; then
        echo "agent-entrypoint: OpenCode requires router base URL and key." >&2
        exit 64
      fi
      opencode_models_response=$(curl -sS --connect-timeout 10 --max-time 30 \
        -w $'\n%{http_code}' \
        -H @<(printf 'Authorization: Bearer %s\nUser-Agent: dryvist-sandbox\nx-opencode-session: %s\n' \
          "$AGENT_ROUTER_KEY" "$AGENT_RUN_ID") \
        "${AGENT_ROUTER_BASE_URL%/}/models" 2>/dev/null) || {
        echo "agent-entrypoint: router models request failed." >&2
        exit 65
      }
      opencode_http_status=${opencode_models_response##*$'\n'}
      opencode_models_json=${opencode_models_response%$'\n'*}
      if [ "$opencode_http_status" != 200 ]; then
        echo "agent-entrypoint: router models request returned HTTP ${opencode_http_status}." >&2
        exit 65
      fi
      if ! jq -e 'type == "object" and (.data | type == "array")' \
        <<<"${opencode_models_json}" >/dev/null 2>&1; then
        echo "agent-entrypoint: router models response is invalid." >&2
        exit 65
      fi
      if ! jq -e '.data | length > 0' <<<"${opencode_models_json}" >/dev/null 2>&1; then
        echo "agent-entrypoint: router models list is empty." >&2
        exit 65
      fi
      if ! opencode_model=$(jq -er \
        '[.data[] | .id? | select(type == "string" and test("^go-[a-z0-9-]+$") and (ascii_downcase | contains("glm") | not))][0] // empty' \
        <<<"${opencode_models_json}" 2>/dev/null); then
        echo "agent-entrypoint: router models list has no non-GLM OpenCode Go model." >&2
        exit 65
      fi
      echo "agent-entrypoint: opencode model ${opencode_model} (router order)" >&2
    else
      opencode_model=medium
    fi
    if [ -n "${AGENT_ROUTER_BASE_URL:-}" ] && [ -n "${AGENT_ROUTER_KEY:-}" ]; then
      opencode_config="${HOME}/.config/opencode/opencode.json"
      mkdir -p "${opencode_config%/*}"
      AGENT_ROUTER_BASE_URL="$AGENT_ROUTER_BASE_URL" AGENT_ROUTER_KEY="$AGENT_ROUTER_KEY" \
        AGENT_RUN_ID="$AGENT_RUN_ID" jq -n --arg model "${opencode_model}" \
        '{provider: {"agent-router": {
          npm: "@ai-sdk/openai-compatible",
          name: "Agent Router",
          options: {baseURL: env.AGENT_ROUTER_BASE_URL, apiKey: env.AGENT_ROUTER_KEY,
            headers: {"User-Agent": "dryvist-sandbox", "x-opencode-session": env.AGENT_RUN_ID}},
          models: {($model): {name: $model}}
        }}}' >"${opencode_config}"
      chmod 600 "${opencode_config}"
      export OPENCODE_CONFIG="${opencode_config}"
    fi
    opencode run --auto --print-logs --log-level warn --model "agent-router/${opencode_model}" "${AGENT_PROMPT}" 2>"${tool_stderr}" || status=$?
    unset AGENT_ROUTER_KEY
    ;;
  shell)
    bash -euo pipefail -c "${AGENT_PROMPT}" 2>"${tool_stderr}" || status=$?
    ;;
  opencode-zai)
    require_zai_model
    zai_subscription_key=${ZAI_SUBSCRIPTION_KEY}
    unset ZAI_SUBSCRIPTION_KEY
    ZHIPU_API_KEY="${zai_subscription_key}" opencode run --auto --print-logs --log-level warn \
      --model "zai-coding-plan/${zai_model}" "${AGENT_PROMPT}" 2>"${tool_stderr}" || status=$?
    unset zai_subscription_key
    ;;
  cursor-agent)
    require_cursor_api_key
    cursor-agent --print --output-format text --force "${AGENT_PROMPT}" 2>"${tool_stderr}" || status=$?
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
# The tool's stderr is replayed here after it exits. A run that made no commit,
# left the tree clean, and whose tool exited 128 with git's empty-bundle refusal
# has nothing to publish, so it ends 0 instead of failing.
cat "${tool_stderr}" >&2
if [ -n "${branch}" ] && [ "${status}" -eq 128 ] &&
  [ "$(git rev-parse HEAD)" = "${base}" ] && [ -z "$(git status --porcelain)" ] &&
  grep -qxF 'fatal: Refusing to create empty bundle.' "${tool_stderr}"; then
  status=0
  echo "agent-entrypoint: no commits; nothing to publish." >&2
fi
rm -f "${tool_stderr}"
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
# one commit created through the GitHub Git Data REST API: one blob per
# changed path, one tree on the remote head's tree carrying each path's mode
# (100644 or 100755) and its deletions, one commit with the remote head as
# parent, then a fast-forward-only ref update (force false), or a ref create
# when the branch is new. GitHub signs commits created through the API for
# the job's App token, as it does createCommitOnBranch commits (see
# "Signature verification for bots" on the "About commit signature
# verification" page, docs.github.com/authentication/managing-commit-
# signature-verification/about-commit-signature-verification). Local commits
# are never pushed. The ref update refuses a non-fast-forward, and both
# limits are checked before anything reaches origin:
# ponytail: contents and modes only. A symlink, a submodule, or a real mode
# change is refused; the API carries git modes but no symlink or gitlink
# objects.
# ponytail: the change is capped at AGENT_PUBLISH_MAX_BYTES of encoded
# contents (default 8 MiB); upgrade to several chained commits if real runs
# need more.
# publish_to_branch <owner/name> <branch> <head sha> <changes file> <exists>:
# the one publish path. Builds the tree on the head's tree so the changes
# keep their git modes, commits it with the head as parent, then moves the
# branch fast-forward only (a non-fast-forward head refuses the update).
publish_to_branch() {
  local repo=$1 br=$2 head=$3 changes=$4 exists=$5
  local tmp tree_sha entry entry_path entry_mode blob_sha new_tree new_commit
  tmp="$(mktemp -d)"
  tree_sha="$(git rev-parse "${head}^{tree}")"
  : >"${tmp}/tree"
  while IFS= read -r entry; do
    if [ "$(jq -r 'has("contents")' <<<"${entry}")" = true ]; then
      jq -j '.contents' <<<"${entry}" >"${tmp}/contents.b64"
      jq -n --rawfile c "${tmp}/contents.b64" '{content: $c, encoding: "base64"}' \
        >"${tmp}/blob.json"
      blob_sha="$(gh api -X POST "repos/${repo}/git/blobs" --input "${tmp}/blob.json" --jq .sha)" || {
        rm -rf "${tmp}"
        return 1
      }
      entry_path="$(jq -r '.path' <<<"${entry}")"
      entry_mode="$(jq -r '.mode' <<<"${entry}")"
      jq -cn --arg p "${entry_path}" --arg m "${entry_mode}" --arg s "${blob_sha}" \
        '{path: $p, mode: $m, type: "blob", sha: $s}' >>"${tmp}/tree"
    else
      jq -cn --arg p "$(jq -r '.path' <<<"${entry}")" '{path: $p, sha: null}' >>"${tmp}/tree"
    fi
  done <"${changes}"
  jq -s --arg b "${tree_sha}" '{base_tree: $b, tree: .}' "${tmp}/tree" >"${tmp}/tree.json"
  new_tree="$(gh api -X POST "repos/${repo}/git/trees" --input "${tmp}/tree.json" --jq .sha)" || {
    rm -rf "${tmp}"
    return 1
  }
  jq -n --arg t "${new_tree}" --arg p "${head}" \
    --arg h "feat(agent): ${AGENT_TOOL} run ${AGENT_RUN_ID}" \
    --arg b "$(git log --reverse --format='- %s' "${base}..HEAD")" \
    '{message: (if $b == "" then $h else ($h + "\n\n" + $b) end), tree: $t, parents: [$p]}' \
    >"${tmp}/commit.json"
  new_commit="$(gh api -X POST "repos/${repo}/git/commits" --input "${tmp}/commit.json" --jq .sha)" || {
    rm -rf "${tmp}"
    return 1
  }
  if [ "${exists}" = 1 ]; then
    jq -n --arg s "${new_commit}" '{sha: $s, force: false}' >"${tmp}/ref.json"
    gh api -X PATCH "repos/${repo}/git/refs/heads/${br}" --input "${tmp}/ref.json" >/dev/null || {
      rm -rf "${tmp}"
      return 1
    }
  else
    gh api "repos/${repo}/git/refs" -f "ref=refs/heads/${br}" \
      -f "sha=${new_commit}" >/dev/null || {
      rm -rf "${tmp}"
      return 1
    }
  fi
  rm -rf "${tmp}"
}

signed_push() {
  local remote_head="" exists=0 tmp
  local max="${AGENT_PUBLISH_MAX_BYTES:-8388608}"
  if remote_head="$(git ls-remote --exit-code origin "refs/heads/${branch}" | cut -f1)"; then
    exists=1
    git fetch -q origin "${branch}"
  else
    remote_head="$(git rev-parse origin/HEAD)"
  fi
  tmp="$(mktemp -d)"
  if ! collect_changes "${remote_head}" "${tmp}/changes" HEAD; then
    rm -rf "${tmp}"
    return 1
  fi
  if [ ! -s "${tmp}/changes" ]; then
    rm -rf "${tmp}"
    return 0
  fi
  if [ "$(wc -c <"${tmp}/changes")" -gt "${max}" ]; then
    echo "agent-entrypoint: the change is larger than ${max} bytes encoded; nothing was published." >&2
    rm -rf "${tmp}"
    return 1
  fi
  if ! publish_to_branch "${AGENT_REPO}" "${branch}" "${remote_head}" \
    "${tmp}/changes" "${exists}"; then
    rm -rf "${tmp}"
    return 1
  fi
  rm -rf "${tmp}"
}

# The run PR may not merge itself: an armed auto-merge merges the PR as soon
# as checks go green, before the required independent review, and a draft is
# not open for review at all. After the PR is created or found it is marked
# ready and disarmed, and only then is the URL emitted; every failed guard
# refuses success.
settle_pr() {
  local info url
  if ! info="$(gh pr view "$1" --json url,isDraft,autoMergeRequest)"; then
    echo "agent-entrypoint: PR lookup failed for $1; refusing to report success." >&2
    return 1
  fi
  url="$(jq -r '.url // empty' <<<"${info}")"
  if [ -z "${url}" ]; then
    echo "agent-entrypoint: PR lookup returned no URL; refusing to report success." >&2
    return 1
  fi
  if [ "$(jq -r '.isDraft // false' <<<"${info}")" = true ] && ! gh pr ready "${url}" >/dev/null; then
    echo "agent-entrypoint: the PR for $1 is still a draft; refusing to report success." >&2
    return 1
  fi
  # Only disarmed when the PR carries an auto-merge request; the mutation
  # rejects a PR without one.
  if [ "$(jq -r '(.autoMergeRequest // null) != null' <<<"${info}")" = true ] \
    && ! gh pr merge "${url}" --disable-auto >/dev/null; then
    echo "agent-entrypoint: auto-merge stays armed on ${url}; refusing to report success." >&2
    return 1
  fi
  printf '%s\n' "${url}"
}

# Only this step writes the PR URL file agent-dispatch reads, so anything the
# tool left at that path is removed first.
pr_file="${workdir}/.agent-pr-url"
rm -rf "${pr_file}"
if [ -n "${branch}" ] && [ -n "$(git status --porcelain)" ]; then
  git add -A
  # The prompt never enters published text: commit messages and PR bodies are public on public repos.
  git commit -m "feat(agent): ${AGENT_TOOL} run ${AGENT_RUN_ID}

Assisted-by: ${AGENT_TOOL} (nix-agent-sandbox)"
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
  # Agent PRs open ready with no label; an existing PR for the branch is success.
  pr_created=1
  if ! url="$(gh pr create --head "${branch}" \
    --title "feat(agent): autonomous ${AGENT_TOOL} run ${AGENT_RUN_ID}" \
    --body "Autonomous run by nix-agent-sandbox.

Agent-authored change.

- Tool: ${AGENT_TOOL}
- Run id: ${AGENT_RUN_ID}
- Exit status: ${status}")"; then
    # A continued run pushes to the branch of the PR it already opened.
    pr_created=0
  fi
  if url="$(settle_pr "${branch}")"; then
    printf '%s\n' "${url}" | tee "${pr_file}"
  else
    if [ "${pr_created}" = 0 ]; then
      echo "agent-entrypoint: PR creation failed; branch ${branch} was published." >&2
    fi
    [ "${status}" -ne 0 ] || status=1
  fi
fi

exit "${status}"
