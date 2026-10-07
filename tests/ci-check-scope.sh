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

expect $'full=true\nimage=true\ntargets=' push refs/heads/main
expect $'full=false\nimage=false\ntargets=' push refs/heads/develop
expect $'full=false\nimage=false\ntargets=agent-cli-spool' workflow_dispatch refs/heads/main
expect $'full=false\nimage=false\ntargets=agent-cli,agent-cli-spool' pull_request refs/pull/1/merge scripts/agent-cli.sh
expect $'full=false\nimage=true\ntargets=agent-image' pull_request refs/pull/1/merge tests/agent-image-smoke.bats
expect $'full=false\nimage=false\ntargets=sandbox-contract' pull_request refs/pull/1/merge nix/task-profiles.nix
expect $'full=false\nimage=false\ntargets=' pull_request refs/pull/1/merge .github/workflows/build-image.yml scripts/ci-check-scope.sh tests/ci-check-scope.sh
expect $'full=false\nimage=false\ntargets=' pull_request refs/pull/1/merge README.md

if env -u GITHUB_OUTPUT bash "$selector" pull_request refs/pull/1/merge scripts/new-runtime.sh >/dev/null 2>&1; then
  echo 'Unmapped code paths must fail until assigned a focused check.' >&2
  exit 1
fi

grep -Fq "name: Build (\${{ matrix.arch }})" "$workflow"
grep -A 2 -F -- '- name: Full flake suite' "$workflow" |
  grep -Fq "if: steps.scope.outputs.full == 'true'"
grep -Fq 'run: nix flake check -L' "$workflow"

echo 'CI event and path selection contract passed.'
