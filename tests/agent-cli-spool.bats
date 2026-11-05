#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  export SPOOL_DIR="${BATS_TEST_TMPDIR}/spool"
  export IMAGE="agent:test"
  export STUB_LOG="${BATS_TEST_TMPDIR}/docker.log"
  docker() { printf '%s\n' "$*" >>"$STUB_LOG"; }
  export -f docker
  # Exercise the launcher's actual mount builder without starting a container.
  # shellcheck disable=SC1090
  source <(sed -n '/^spool_mount_flags() {/,/^}/p' "$AGENT_CLI_SOURCE")
}

@test "host spool mounts ZCode CLI JSONL logs" {
  local flags
  flags="$(spool_mount_flags run-123)"

  [[ "$flags" == *"${SPOOL_DIR}/run-123/zcode:/home/agent/.zcode/cli/log"* ]]
  grep -Fq "/spool/run-123/zcode" "$STUB_LOG"
}

@test "sweep is retired: exits before any container and names the dispatcher" {
  run bash "$AGENT_CLI_SOURCE" sweep --group nix "hello"
  [ "$status" -eq 64 ]
  [[ "$output" == *"local sweep runs are retired; start the jobs through the dispatcher: zcode-job start <owner/repo> <prompt>"* ]]
  [ ! -e "$STUB_LOG" ]
}

@test "run --repo is retired: exits before any container and names the dispatcher" {
  run bash "$AGENT_CLI_SOURCE" run --repo dryvist/example "hello"
  [ "$status" -eq 64 ]
  [[ "$output" == *"local --repo runs are retired; start the job through the dispatcher: zcode-job start <owner/repo> <prompt>"* ]]
  [ ! -e "$STUB_LOG" ]
}

@test "run without --repo passes no GitHub token into the container" {
  export DOCKER_HOST=unix:///dev/null AGENT_TIMEOUT=1
  export GH_TOKEN=sentinel-gh GITHUB_TOKEN=sentinel-github ANTHROPIC_API_KEY=sentinel-anthropic
  run bash "$AGENT_CLI_SOURCE" run --no-oauth "hello"
  [ "$status" -eq 0 ]
  run ! grep -Eq 'GH_TOKEN=|GITHUB_TOKEN=' "$STUB_LOG"
  grep -Fq 'ANTHROPIC_API_KEY=sentinel-anthropic' "$STUB_LOG"
}

@test "routed and qwen env forwards carry no GitHub token" {
  export GH_TOKEN=sentinel-gh GITHUB_TOKEN=sentinel-github AGENT_ROUTER_KEY=sentinel-router
  # Exercise the launcher's actual env-flag builder without starting a container.
  # shellcheck disable=SC1090
  source <(sed -n '/^env_flags() {/,/^}/p' "$AGENT_CLI_SOURCE")
  local tool flags
  for tool in zcode opencode cursor-agent qwen claude; do
    flags="$(env_flags "$tool")"
    [[ "$flags" != *GH_TOKEN=* ]]
    [[ "$flags" != *GITHUB_TOKEN=* ]]
  done
  [[ "$(env_flags zcode)" == *"AGENT_ROUTER_KEY=sentinel-router"* ]]
}
