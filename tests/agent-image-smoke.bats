#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  export SANDBOX_IMAGE_UNDER_TEST="${AGENT_IMAGE_UNDER_TEST:-ghcr.io/dryvist/nix-agent-sandbox/agent:latest}"
}

@test "all agent CLIs print a version as uid 1000 without baked OpenCode provider config" {
  run docker run --rm --user 1000:1000 --entrypoint /bin/bash "$SANDBOX_IMAGE_UNDER_TEST" \
    -euo pipefail -c '
      test "$(id -u)" = 1000
      test ! -e /home/agent/.config/opencode/opencode.json
      for binary in qwen zcode opencode cursor-agent; do
        command -v "$binary" >/dev/null
        version="$("$binary" --version)"
        test -n "$version"
      done
    '
  [ "$status" -eq 0 ]
}

@test "repo-check toolchain is on PATH as uid 1000 without network" {
  run docker run --rm --network none --user 1000:1000 --entrypoint /bin/bash "$SANDBOX_IMAGE_UNDER_TEST" \
    -euo pipefail -c '
      # Same list as requiredBinaries in nix/agent-image-toolchain.nix;
      # enforced at build time by .#checks.<system>.agent-image-toolchain.
      for binary in actionlint ansible-lint ansible-playbook jq nixfmt pre-commit pytest python3 ruff shellcheck yamllint yq; do
        command -v "$binary" >/dev/null
      done
      python3 -c "import pytest, yaml, jinja2"
      yq --version | grep -q "mikefarah/yq.*v4\."
    '
  [ "$status" -eq 0 ]
}

@test "image environment contains no credential field or OpenBao address" {
  docker image inspect --format '{{json .Config.Env}}' "$SANDBOX_IMAGE_UNDER_TEST" |
    jq -e '
      all(.[];
        ((split("=")[0] | test("key|token|secret|password|credential|openbao|bao[_-]?addr|vault"; "i")) | not)
      ) and
      all(.[];
        ((split("=")[1:] | join("=") | test("openbao|vault|bao\\.test"; "i")) | not)
      )
    ' >/dev/null
}
