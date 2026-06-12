# The `agent` dispatch CLI (wrapped by writeShellApplication).
#
# Launches the agent image with Apple `container` (preferred on macOS) or
# Docker. Autonomy comes from the image, not from how the host shell was
# blessed.

IMAGE="${AGENT_IMAGE:-ghcr.io/dryvist/nix-agent-sandbox/agent:latest}"

usage() {
  cat >&2 <<'EOF'
usage:
  agent run [--tool claude|codex|gemini] [--repo owner/name] <prompt...>
  agent shell

Runs the prompt fully autonomously inside a disposable container (--rm;
the only durable output is a pushed branch/PR when --repo is given).
Pass credentials via environment: ANTHROPIC_API_KEY / OPENAI_API_KEY /
GEMINI_API_KEY for the model, GH_TOKEN (repo-scoped) for --repo.
Override the image with AGENT_IMAGE.
EOF
  exit 64
}

runtime() {
  if command -v container >/dev/null 2>&1; then
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
  for var in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY GH_TOKEN GITHUB_TOKEN; do
    if [ -n "${!var:-}" ]; then
      printf -- '-e\n%s=%s\n' "$var" "${!var}"
    fi
  done
}

cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in
  run)
    tool=claude
    repo=""
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

    rt="$(runtime)"
    flags=()
    while IFS= read -r line; do flags+=("$line"); done < <(env_flags)
    exec "$rt" run --rm \
      -e AGENT_TOOL="$tool" \
      -e AGENT_REPO="$repo" \
      -e AGENT_PROMPT="$prompt" \
      "${flags[@]}" \
      "$IMAGE"
    ;;
  shell)
    rt="$(runtime)"
    exec "$rt" run --rm -it -e AGENT_SHELL=1 "$IMAGE"
    ;;
  *)
    usage
    ;;
esac
