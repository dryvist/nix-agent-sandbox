# The `agent` dispatch CLI (wrapped by writeShellApplication).
#
# Launches the agent image with Apple `container` (preferred on macOS) or
# Docker — locally, or on the docker-host VM via --host (DOCKER_HOST=ssh://).
# Autonomy comes from the image, not from how the host shell was blessed.

IMAGE="${AGENT_IMAGE:-ghcr.io/dryvist/nix-agent-sandbox/agent:latest}"

usage() {
  cat >&2 <<'EOF'
usage:
  agent run [--tool claude|codex|gemini] [--repo owner/name]
            [--host fqdn] [--profile name] [--no-oauth] <prompt...>
  agent sweep --group name [--concurrency N] [--tool claude|codex|gemini]
            [--host fqdn] [--profile name] [--no-oauth] <prompt...>
  agent shell [--host fqdn]

Runs the prompt fully autonomously inside a disposable container (--rm;
the only durable output is a pushed branch/PR when --repo is given).

`sweep` fans the same prompt out across every repo in a named group (see
lib.repoGroups / nix/repo-groups.nix), one disposable container per repo —
each cloning, branching, and PR'ing its own repo with its own repo-scoped
GitHub token, exactly like `agent run --repo`. At most --concurrency runs
(default 4) execute at once; an end-of-run table lists each repo, its base
branch, and the PR URL or exit code. A group's `profile` is the default
unless --profile overrides it. Per-repo github-write material is required
just as for `run --repo`.

The workstation's subscription-OAuth credentials for the selected --tool
are injected into the container per run (never baked into the image, never
passed via -e): claude prefers an exported CLAUDE_CODE_OAUTH_TOKEN (from
`claude setup-token`; a long-lived token, so no per-run file copy needed),
else ~/.claude/.credentials.json, else the macOS Keychain "Claude
Code-credentials" item; codex reads ${CODEX_HOME:-~/.codex}/auth.json;
gemini reads ~/.gemini/oauth_creds.json (+ installation_id,
google_accounts.json if present). This needs the docker runtime — Apple
`container` has no stdin-tar `cp`, so injection is refused there. Missing
or (for claude/gemini) expired source credentials are a hard failure
naming what to refresh, not a silent skip. --no-oauth opts out entirely,
for API-key auth instead.

--host runs on that Docker host over SSH (DOCKER_HOST=ssh://fqdn) and
attaches the container to its egress-allowlisted network (AGENT_NETWORK,
default "agents"; proxy AGENT_PROXY_URL, default http://proxy:3128).

--profile selects a task profile baked into the image: its KV secret group
is fetched from OpenBao. Requires BAO_ADDR plus AppRole material —
BAO_ROLE_ID/BAO_SECRET_ID (defaulting to the ambient AI_READONLY_* pair) or
a human-minted single-use BAO_WRAPPED_SECRET_ID for the ai-apply tiers.

--repo additionally mints a per-run, single-repo-scoped GitHub App token via
OpenBao's github-write identity (a claim-before-work write-lease, ~15m,
prevents two concurrent runs from both writing the same repo) — unless a
caller-supplied GH_TOKEN is already in the environment, which always wins.
Requires BAO_ADDR, OPENBAO_APPROLE_GITHUB_WRITE_ROLE_ID/_SECRET_ID, and the
matching OPENBAO_GITHUB_<DRYVIST|PERSONAL>_INSTALLATION_ID for the repo's
owner.

With --no-oauth (or for --tool values with no OAuth path), pass credentials
via environment instead: ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY
for the model, GH_TOKEN (repo-scoped) for --repo. Override the image with
AGENT_IMAGE.
EOF
  exit 64
}

runtime() {
  # A remote --host is Docker-only; Apple `container` has no remote engine.
  if [ -n "${DOCKER_HOST:-}" ]; then
    echo docker
  elif command -v container >/dev/null 2>&1; then
    echo container
  elif command -v docker >/dev/null 2>&1; then
    echo docker
  else
    echo "agent: need Apple 'container' or docker on PATH" >&2
    exit 69
  fi
}

# Forward only the credentials that are actually set. Values are passed
# explicitly (KEY=VALUE) because Apple `container` does not support
# bare-name env passthrough the way docker does.
env_flags() {
  for var in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY \
    CLAUDE_CODE_OAUTH_TOKEN \
    GH_TOKEN GITHUB_TOKEN BAO_ADDR BAO_ROLE_ID BAO_SECRET_ID BAO_WRAPPED_SECRET_ID; do
    if [ -n "${!var:-}" ]; then
      printf -- '-e\n%s=%s\n' "$var" "${!var}"
    fi
  done
}

# --- GitHub write-token minting (launcher-side; the container never holds
# github-write reach — see entrypoint.sh). One repo per request, parameter-
# pinned server-side by the github-write OpenBao policy. No coordination
# lock: each run clones fresh and pushes its own uniquely-named branch, so
# there is no shared git state for concurrent same-repo runs to race on —
# git's own non-fast-forward push rejection is what would catch a real
# collision, and GitHub Apps support any number of simultaneously-valid
# installation tokens, so serializing the mint itself protects nothing.
mint_github_token() {
  local repo="$1" bao_addr owner iid role_id secret_id bao_tok resp
  bao_addr="${BAO_ADDR:-${VAULT_ADDR:-}}"
  [ -n "${bao_addr}" ] || {
    echo "agent: --repo requires BAO_ADDR (or VAULT_ADDR) to mint a GitHub write token." >&2
    exit 64
  }
  owner="${repo%%/*}"
  case "${owner}" in
    dryvist) iid="${OPENBAO_GITHUB_DRYVIST_INSTALLATION_ID:-}" ;;
    *) iid="${OPENBAO_GITHUB_PERSONAL_INSTALLATION_ID:-}" ;;
  esac
  [ -n "${iid}" ] || {
    echo "agent: no installation id for owner '${owner}' (set OPENBAO_GITHUB_${owner^^}_INSTALLATION_ID)." >&2
    exit 64
  }
  role_id="${OPENBAO_APPROLE_GITHUB_WRITE_ROLE_ID:-}"
  secret_id="${OPENBAO_APPROLE_GITHUB_WRITE_SECRET_ID:-}"
  [ -n "${role_id}" ] && [ -n "${secret_id}" ] || {
    echo "agent: --repo requires OPENBAO_APPROLE_GITHUB_WRITE_ROLE_ID/_SECRET_ID." >&2
    exit 64
  }

  bao_tok="$(curl -fsS --max-time 10 -X POST \
      -d "$(jq -cn --arg r "${role_id}" --arg s "${secret_id}" '{role_id:$r,secret_id:$s}')" \
      "${bao_addr}/v1/auth/approle/login" \
    | jq -re '.auth.client_token')" || {
    echo "agent: github-write AppRole login failed." >&2
    exit 64
  }

  # String forms are load-bearing: OpenBao's github-write ACL cannot
  # element-match a LIST parameter and only matches installation_id as a
  # string (ansible-proxmox-apps#1104, verified live 2026-07-18) — the
  # number/list shape is denied server-side.
  resp="$(curl -fsS --max-time 10 -X POST -H "X-Vault-Token: ${bao_tok}" \
      -d "$(jq -cn --arg i "${iid}" --arg r "${repo##*/}" '{installation_id:$i,repositories:$r}')" \
      "${bao_addr}/v1/github/token")" || {
    echo "agent: minting the github-write token for ${repo} failed (repo not on the allowlist?)." >&2
    unset bao_tok role_id secret_id
    exit 64
  }
  GH_TOKEN="$(jq -re '.data.token' <<<"${resp}")" || {
    echo "agent: no token in the github-write mint response for ${repo}." >&2
    unset bao_tok role_id secret_id resp
    exit 64
  }
  GITHUB_TOKEN="${GH_TOKEN}"
  export GH_TOKEN GITHUB_TOKEN
  # Bootstrap material dies here — it must never reach the container (the
  # exec below only forwards what env_flags() explicitly enumerates).
  unset bao_tok role_id secret_id resp
}

# --- Subscription-OAuth credential injection (launcher-side only; the
# container never bakes these in and never receives them via -e/`docker run
# -e`, which would leak into `docker inspect` and shell history on any
# remote host). One tar stream, written only for the selected --tool, piped
# into the container's home dir between `docker create` and `docker start`
# via `docker cp -`. Requires docker: Apple `container copy` has no
# stdin-tar form, so callers on that runtime must pass --no-oauth.
oauth_paths() { # tool -> "src\tdest" lines; dest is relative to /home/agent
  case "$1" in
    claude)
      printf '%s\t%s\n' "${HOME}/.claude/.credentials.json" .claude/.credentials.json
      ;;
    codex)
      printf '%s\t%s\n' "${CODEX_HOME:-${HOME}/.codex}/auth.json" .codex/auth.json
      ;;
    gemini)
      printf '%s\t%s\n' "${HOME}/.gemini/oauth_creds.json" .gemini/oauth_creds.json
      printf '%s\t%s\n' "${HOME}/.gemini/installation_id" .gemini/installation_id
      printf '%s\t%s\n' "${HOME}/.gemini/google_accounts.json" .gemini/google_accounts.json
      ;;
  esac
}

inject_oauth_creds() {
  local cid="$1" tool="$2" tmp found=0 blob now_ms exp

  # `claude setup-token` mints a long-lived token meant for exactly this
  # (headless/CI) use case — prefer it over the interactive session's
  # credentials file when the caller already has one exported, since it
  # sidesteps both the file-injection path and the refresh-rotation risk
  # noted in the README. env_flags() forwards it; nothing to inject here.
  if [ "$tool" = claude ] && [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    return 0
  fi

  # +%3N is GNU-only; BSD/macOS date lacks it. Whole-seconds*1000 keeps the
  # claude/gemini ms-epoch comparisons correct to within 1s.
  now_ms="$(( $(date +%s) * 1000 ))"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  chmod 700 "$tmp"

  while IFS=$'\t' read -r src dest; do
    if [ -f "$src" ]; then
      mkdir -p "$tmp/$(dirname "$dest")"
      cp "$src" "$tmp/$dest"
      found=1
    fi
  done < <(oauth_paths "$tool")

  # claude has no auth.json-on-disk guarantee outside a logged-in CLI
  # session; the desktop app's login instead lands in Keychain.
  if [ "$tool" = claude ] && [ "$found" -eq 0 ]; then
    blob="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)" || true
    if [ -n "$blob" ]; then
      mkdir -p "$tmp/.claude"
      printf '%s' "$blob" >"$tmp/.claude/.credentials.json"
      found=1
    fi
  fi

  if [ "$found" -eq 0 ]; then
    echo "agent: no subscription-OAuth credentials found for --tool ${tool}." >&2
    case "$tool" in
      claude) echo "agent: run 'claude setup-token' and export CLAUDE_CODE_OAUTH_TOKEN, or log into Claude Code interactively." >&2 ;;
      codex) echo "agent: run 'codex login' to populate ${CODEX_HOME:-${HOME}/.codex}/auth.json." >&2 ;;
      gemini) echo "agent: log into the gemini CLI to populate ~/.gemini/oauth_creds.json." >&2 ;;
    esac
    echo "agent: or pass --no-oauth to run with API-key auth instead." >&2
    exit 64
  fi

  # Reject a known-dead refresh token here rather than shipping it into
  # the container to fail loudly there after burning a whole run. Only
  # claude/gemini expose a checkable expiry on disk; codex's auth.json has
  # none (nothing to compare against), and is refreshed by the CLI itself.
  case "$tool" in
    claude)
      exp="$(jq -re '.claudeAiOauth.refreshTokenExpiresAt // empty' "${tmp}/.claude/.credentials.json" 2>/dev/null)" || exp=""
      if [ -n "$exp" ] && [ "$exp" -lt "$now_ms" ]; then
        echo "agent: claude's stored refresh token expired; run 'claude setup-token' and export CLAUDE_CODE_OAUTH_TOKEN, or log in interactively." >&2
        exit 64
      fi
      ;;
    gemini)
      exp="$(jq -re '.expiry_date // empty' "${tmp}/.gemini/oauth_creds.json" 2>/dev/null)" || exp=""
      if [ -n "$exp" ] && [ "$exp" -lt "$now_ms" ]; then
        echo "agent: gemini's stored OAuth token expired; log into the gemini CLI to refresh ~/.gemini/oauth_creds.json." >&2
        exit 64
      fi
      ;;
  esac

  chmod -R go-rwx "$tmp"
  # --owner/--group re-home the archive to the container's non-root agent
  # user (uid/gid 1000) so the entrypoint can read what root's docker cp
  # wrote — see nix/agent-image.nix homeDir and its uid 1000 `agent` user.
  tar --owner=1000:1000 --group=1000:1000 -C "$tmp" -cf - . \
    | docker cp - "${cid}:/home/agent/"
}

# --host: run on that Docker host and join its egress-allowlisted network.
host_flags=()
apply_host() {
  export DOCKER_HOST="ssh://$1"
  local proxy="${AGENT_PROXY_URL:-http://proxy:3128}"
  host_flags=(
    --network "${AGENT_NETWORK:-agents}"
    -e "HTTP_PROXY=${proxy}"
    -e "HTTPS_PROXY=${proxy}"
    -e "http_proxy=${proxy}"
    -e "https_proxy=${proxy}"
  )
}

cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in
  run)
    tool=claude
    repo=""
    profile=""
    no_oauth=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --tool)
          tool="$2"
          shift 2
          ;;
        --repo)
          repo="$2"
          shift 2
          ;;
        --host)
          apply_host "$2"
          shift 2
          ;;
        --profile)
          profile="$2"
          shift 2
          ;;
        --no-oauth)
          no_oauth=1
          shift
          ;;
        --)
          shift
          break
          ;;
        -*)
          usage
          ;;
        *)
          break
          ;;
      esac
    done
    [ $# -gt 0 ] || usage
    prompt="$*"

    # Ambient ai-readonly AppRole is the estate default for profile runs.
    : "${BAO_ROLE_ID:=${AI_READONLY_ROLE_ID:-}}"
    : "${BAO_SECRET_ID:=${AI_READONLY_SECRET_ID:-}}"

    if [ -n "${repo}" ] && [ -z "${GH_TOKEN:-}" ]; then
      mint_github_token "${repo}"
    fi

    rt="$(runtime)"
    flags=()
    while IFS= read -r line; do flags+=("$line"); done < <(env_flags)
    run_flags=(
      -e "AGENT_TOOL=$tool"
      -e "AGENT_REPO=$repo"
      -e "AGENT_PROFILE=$profile"
      -e "AGENT_PROMPT=$prompt"
      "${host_flags[@]}"
      "${flags[@]}"
    )

    if [ "${no_oauth}" -eq 1 ]; then
      exec "$rt" run --rm "${run_flags[@]}" "$IMAGE"
    fi
    [ "$rt" = docker ] || {
      echo "agent: OAuth credential injection needs the docker runtime (got '${rt}'); pass --no-oauth to run without it." >&2
      exit 64
    }
    cid="$(docker create --rm "${run_flags[@]}" "$IMAGE")"
    inject_oauth_creds "$cid" "$tool"
    exec docker start -a "$cid"
    ;;
  sweep)
    # Launcher-side fan-out: one `agent run --repo` per group member. Each
    # member re-invokes this same CLI ("$0"), so it reuses the identical
    # token-mint + OAuth-injection + container path — one repo per run, the
    # law held. Nothing about the container changes for a sweep.
    group=""
    concurrency=4
    tool=claude
    profile=""
    host=""
    no_oauth=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --group)
          group="$2"
          shift 2
          ;;
        --concurrency)
          concurrency="$2"
          shift 2
          ;;
        --tool)
          tool="$2"
          shift 2
          ;;
        --host)
          host="$2"
          shift 2
          ;;
        --profile)
          profile="$2"
          shift 2
          ;;
        --no-oauth)
          no_oauth=1
          shift
          ;;
        --)
          shift
          break
          ;;
        -*)
          usage
          ;;
        *)
          break
          ;;
      esac
    done
    [ -n "${group}" ] || usage
    [ $# -gt 0 ] || usage
    prompt="$*"

    case "${concurrency}" in
      '' | *[!0-9]*) usage ;;
    esac
    [ "${concurrency}" -ge 1 ] || concurrency=1

    [ -n "${AGENT_REPO_GROUPS:-}" ] || {
      echo "agent: no repo-group table baked in; run the nix-built 'agent' (not the raw script)." >&2
      exit 70
    }
    group_json="$(jq -ce --arg g "${group}" '.[$g]' <<<"${AGENT_REPO_GROUPS}")" || group_json="null"
    if [ "${group_json}" = "null" ]; then
      echo "agent: unknown group '${group}'. Known groups:" >&2
      jq -r 'keys[]' <<<"${AGENT_REPO_GROUPS}" | sed 's/^/  /' >&2
      exit 64
    fi
    # Group profile is the default; an explicit --profile wins.
    [ -n "${profile}" ] || profile="$(jq -re '.profile // ""' <<<"${group_json}")"

    repos=()
    while IFS= read -r entry; do repos+=("${entry}"); done \
      < <(jq -r '.repos[] | [.name, .branch] | @tsv' <<<"${group_json}")
    [ "${#repos[@]}" -gt 0 ] || {
      echo "agent: group '${group}' has no repos." >&2
      exit 64
    }

    sweep_tmp="$(mktemp -d)"
    trap 'rm -rf "${sweep_tmp}"' EXIT

    # Every member is owner dryvist (repo-groups.nix records name only).
    run_member() {
      local name="$1" idx="$2" args rc=0
      args=(run --repo "dryvist/${name}" --tool "${tool}")
      [ -n "${profile}" ] && args+=(--profile "${profile}")
      [ -n "${host}" ] && args+=(--host "${host}")
      [ "${no_oauth}" -eq 1 ] && args+=(--no-oauth)
      args+=(-- "${prompt}")
      "$0" "${args[@]}" >"${sweep_tmp}/${idx}.out" 2>&1 || rc=$?
      echo "${rc}" >"${sweep_tmp}/${idx}.rc"
    }

    # Fan out in batches of --concurrency (portable; no `wait -n` needed).
    idx=0
    for entry in "${repos[@]}"; do
      IFS=$'\t' read -r name _branch <<<"${entry}"
      run_member "${name}" "${idx}" &
      idx=$((idx + 1))
      [ "$((idx % concurrency))" -eq 0 ] && wait
    done
    wait

    # Summary table + overall exit: nonzero if any member failed.
    printf '\n%-30s %-10s %s\n' "REPO" "BRANCH" "RESULT"
    overall=0
    idx=0
    for entry in "${repos[@]}"; do
      IFS=$'\t' read -r name branch <<<"${entry}"
      rc="$(cat "${sweep_tmp}/${idx}.rc" 2>/dev/null || echo '?')"
      pr="$(grep -Eom1 'https://github\.com/[^ ]+/pull/[0-9]+' \
        "${sweep_tmp}/${idx}.out" 2>/dev/null || true)"
      if [ -n "${pr}" ]; then
        result="${pr}"
      else
        result="exit ${rc}"
      fi
      [ "${rc}" = 0 ] || overall=1
      printf '%-30s %-10s %s\n' "dryvist/${name}" "${branch}" "${result}"
      idx=$((idx + 1))
    done
    exit "${overall}"
    ;;
  shell)
    while [ $# -gt 0 ]; do
      case "$1" in
        --host)
          apply_host "$2"
          shift 2
          ;;
        *)
          usage
          ;;
      esac
    done
    rt="$(runtime)"
    flags=()
    while IFS= read -r line; do flags+=("$line"); done < <(env_flags)
    exec "$rt" run --rm -it -e AGENT_SHELL=1 "${host_flags[@]}" "${flags[@]}" "$IMAGE"
    ;;
  *)
    usage
    ;;
esac
