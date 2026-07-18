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
            [--host fqdn] [--profile name] <prompt...>
  agent shell [--host fqdn]

Runs the prompt fully autonomously inside a disposable container (--rm;
the only durable output is a pushed branch/PR when --repo is given).

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

Without --profile/--repo, pass credentials via environment as before:
ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY for the model,
GH_TOKEN (repo-scoped) for --repo. Override the image with AGENT_IMAGE.
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

  resp="$(curl -fsS --max-time 10 -X POST -H "X-Vault-Token: ${bao_tok}" \
      -d "$(jq -cn --argjson i "${iid}" --arg r "${repo##*/}" '{installation_id:$i,repositories:[$r]}')" \
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
    exec "$rt" run --rm \
      -e AGENT_TOOL="$tool" \
      -e AGENT_REPO="$repo" \
      -e AGENT_PROFILE="$profile" \
      -e AGENT_PROMPT="$prompt" \
      "${host_flags[@]}" \
      "${flags[@]}" \
      "$IMAGE"
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
