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

--profile selects a task profile baked into the image: its secret group is
fetched from OpenBao and a per-run repo-scoped GitHub token is minted.
Requires BAO_ADDR plus AppRole material — BAO_ROLE_ID/BAO_SECRET_ID
(defaulting to the ambient AI_READONLY_* pair) or a human-minted
single-use BAO_WRAPPED_SECRET_ID for the ai-apply tiers.

Without --profile, pass credentials via environment as before:
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
