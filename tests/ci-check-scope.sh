#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
selector=$repo_root/scripts/ci-check-scope.sh
workflow=$repo_root/.github/workflows/build-image.yml

expect() {
  local expected=$1
  shift
  local actual
  actual=$(env -u GITHUB_OUTPUT bash "$selector" "$@")
  [[ $actual == "$expected" ]] || {
    printf 'Expected:\n%s\nGot:\n%s\n' "$expected" "$actual" >&2
    exit 1
  }
}

expect $'image=true\ntargets=' push refs/heads/main
expect $'image=false\ntargets=' push refs/heads/develop
expect $'image=false\ntargets=agent-cli-spool' workflow_dispatch refs/heads/main
expect $'image=false\ntargets=agent-cli,agent-cli-spool' pull_request refs/pull/1/merge scripts/agent-cli.sh
expect $'image=true\ntargets=agent-image' pull_request refs/pull/1/merge tests/agent-image-smoke.bats
expect $'image=true\ntargets=agent-image' pull_request refs/pull/1/merge nix/zammad-mcp.nix
expect $'image=true\ntargets=agent-image' pull_request refs/pull/1/merge scripts/zammad-mcp.sh
expect $'image=false\ntargets=agent-dispatch' pull_request refs/pull/1/merge tests/agent-bao-agent.bats templates/bao-agent/read.hcl
expect $'image=false\ntargets=sandbox-contract' pull_request refs/pull/1/merge nix/task-profiles.nix
expect $'image=false\ntargets=zcode-job-module' pull_request refs/pull/1/merge nix/zcode-job-module.nix
expect $'image=false\ntargets=ci-resolver' pull_request refs/pull/1/merge scripts/ci-resolver.py tests/test_ci_resolver.py
expect $'image=false\ntargets=zcode-job' pull_request refs/pull/1/merge scripts/zcode-model.mjs tests/zcode-web-model.test.mjs
expect $'image=false\ntargets=' pull_request refs/pull/1/merge .github/workflows/build-image.yml scripts/ci-check-scope.sh tests/ci-check-scope.sh
expect $'image=false\ntargets=' pull_request refs/pull/1/merge README.md

if env -u GITHUB_OUTPUT bash "$selector" pull_request refs/pull/1/merge scripts/new-runtime.sh >/dev/null 2>&1; then
  echo 'Unmapped code paths must fail until assigned a focused check.' >&2
  exit 1
fi

# The full flake suite is its own job on a push to main, beside the image build.
grep -Fq "name: Build (\${{ matrix.arch }})" "$workflow"
grep -A 1 -F -- 'name: Full flake suite (' "$workflow" |
  grep -Fq "if: github.event_name == 'push' && github.ref == 'refs/heads/main'"
grep -A 1 -F -- '- name: Full flake suite' "$workflow" |
  grep -Fq 'run: nix flake check -L'
[[ $(grep -Fc 'run: nix flake check -L' "$workflow") == 1 ]]
# The multi-arch tag moves only after the image build and the suite both pass.
grep -Fq 'needs: [build, suite]' "$workflow"

echo 'CI event and path selection contract passed.'
