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
