#!/usr/bin/env bash
set -euo pipefail

event=${1:?event name required}
ref=${2:?git ref required}
shift 2

full=false
image=false
targets=()

add_target() {
  local candidate=$1 existing
  for existing in "${targets[@]}"; do
    [[ $existing == "$candidate" ]] && return
  done
  targets+=("$candidate")
}

if [[ $event == push && $ref == refs/heads/main ]]; then
  full=true
  image=true
elif [[ $event == workflow_dispatch ]]; then
  # Manual runs stay bounded; the post-merge main push owns the full suite.
  add_target agent-cli-spool
elif [[ $event == pull_request ]]; then
  for path in "$@"; do
    case $path in
      flake.nix|flake.lock)
        for target in agent-cli agent-dispatch agent-cli-spool zcode-job sandbox-contract agent-image; do
          add_target "$target"
        done
        image=true
        ;;
      nix/agent-cli.nix|scripts/agent-cli.sh|tests/agent-cli-spool.bats)
        add_target agent-cli
        add_target agent-cli-spool
        ;;
      nix/agent-dispatch.nix|scripts/agent-dispatch.sh|scripts/dispatch-ssh.sh|scripts/entrypoint.sh|tests/agent-dispatch.bats|tests/fixtures/*|tests/stubs/*)
        add_target agent-dispatch
        ;;
      nix/zcode-job.nix|scripts/zcode-job.sh|scripts/zcode-web-task.mjs|scripts/zcode-web-supervisor.mjs|tests/zcode-job.bats|tests/ssh-stub.sh)
        add_target zcode-job
        ;;
      nix/task-profiles.nix|nix/egress-domains.nix|nix/repo-groups.nix)
        add_target sandbox-contract
        ;;
      nix/agent-image.nix|tests/agent-image-smoke.bats|nix/agent-image-*.nix)
        add_target agent-image
        image=true
        ;;
      .github/workflows/build-image.yml|scripts/ci-check-scope.sh|tests/ci-check-scope.sh)
        # The in-workflow contract test validates changes to the selector itself.
        ;;
      scripts/*|nix/*|tests/*)
        printf 'No CI flake-check mapping for changed path: %s\n' "$path" >&2
        exit 2
        ;;
      *) ;;
    esac
  done
fi

targets_csv=$(IFS=,; printf '%s' "${targets[*]}")
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  {
    printf 'full=%s\n' "$full"
    printf 'image=%s\n' "$image"
    printf 'targets=%s\n' "$targets_csv"
  } >> "$GITHUB_OUTPUT"
else
  printf 'full=%s\nimage=%s\ntargets=%s\n' "$full" "$image" "$targets_csv"
fi
