#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Stubs run under the interpreter running the tests; the build sandbox has no /usr/bin/env.
write_stub() { { printf '#!%s\n' "$BASH"; cat; } >"$1"; }

setup() {
  export STUB_DIR="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_DIR/bin"
  export ZCODE_AGENT_CURL_CMD="$STUB_DIR/bin/curl"
  export ZCODE_AGENT_ZCODE_JOB_CMD="$STUB_DIR/bin/zcode-job"
  export PROMPT_FILE="$BATS_TEST_TMPDIR/prompt.md"
  export OUT_FILE="$BATS_TEST_TMPDIR/result.json"
  printf '%s\n' 'Implement the requested change.' >"$PROMPT_FILE"

  write_stub "$ZCODE_AGENT_CURL_CMD" <<'EOF'
set -euo pipefail
if [ "${STUB_REPO_PRIVATE:-}" = 1 ]; then
  printf '%s\n' '{"private":true,"visibility":"private","default_branch":"main"}'
else
  printf '%s\n' '{"private":false,"visibility":"public","default_branch":"develop"}'
fi
EOF
  write_stub "$ZCODE_AGENT_ZCODE_JOB_CMD" <<'EOF'
set -euo pipefail
case "$1" in
  repos)
    if [ "${STUB_REPO_UNAPPROVED:-}" = 1 ]; then
      printf '%s\n' '{"repos":["dryvist/other"]}'
    else
      printf '%s\n' '{"repos":["dryvist/example"]}'
    fi
    ;;
  start)
    if [ "${STUB_JOB_MODE:-}" = quota ]; then
      printf '%s\n' '{"error":"HTTP 429 quota exhausted"}'
      exit 1
    fi
    printf '%s' "$3" >"$STUB_DIR/prompt"
    printf '%s\n' '{"job":"j-0123456789abcdef","repo":"dryvist/example","state":"starting"}'
    ;;
  status)
    if [ "${STUB_JOB_MODE:-}" = failed ]; then
      printf '%s\n' '{"job":"j-0123456789abcdef","repo":"dryvist/example","state":"failed"}'
    else
      printf '%s\n' '{"job":"j-0123456789abcdef","repo":"dryvist/example","state":"succeeded"}'
    fi
    ;;
  result)
    printf '%s\n' '{"job":"j-0123456789abcdef","repo":"dryvist/example","state":"succeeded","result":"completed"}'
    ;;
  cancel) exit 0 ;;
  *) exit 64 ;;
esac
EOF
  chmod +x "$ZCODE_AGENT_CURL_CMD" "$ZCODE_AGENT_ZCODE_JOB_CMD"
}

agent() { "$ZCODE_AGENT_BIN/zcode-agent" "$@"; }

@test "code appends the base branch and requests a draft pull request" {
  run agent code dryvist/example -p "$PROMPT_FILE" -o "$OUT_FILE"
  [ "$status" -eq 0 ]
  grep -Fx 'Target base branch: develop' "$STUB_DIR/prompt"
  grep -F 'draft pull request' "$STUB_DIR/prompt"
  [ "$(jq -r '.result' "$OUT_FILE")" = completed ]
}

@test "review appends the base branch without requesting a pull request" {
  run agent review dryvist/example -p "$PROMPT_FILE" -o "$OUT_FILE"
  [ "$status" -eq 0 ]
  grep -Fx 'Target base branch: develop' "$STUB_DIR/prompt"
  ! grep -F 'pull request' "$STUB_DIR/prompt"
}

@test "owner outside the allowlist is refused before metadata or job lookup" {
  run agent code other/example -p "$PROMPT_FILE" -o "$OUT_FILE"
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_DIR/prompt" ]
  [ ! -e "$OUT_FILE" ]
}

@test "private repositories are refused before starting a job" {
  export STUB_REPO_PRIVATE=1
  run agent triage dryvist/example -p "$PROMPT_FILE" -o "$OUT_FILE"
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_DIR/prompt" ]
  [ ! -e "$OUT_FILE" ]
}

@test "repositories outside the installed subset are refused" {
  export STUB_REPO_UNAPPROVED=1
  run agent code dryvist/example -p "$PROMPT_FILE" -o "$OUT_FILE"
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_DIR/prompt" ]
  [ ! -e "$OUT_FILE" ]
}

@test "quota failures return exit code three" {
  export STUB_JOB_MODE=quota
  run agent code dryvist/example -p "$PROMPT_FILE" -o "$OUT_FILE"
  [ "$status" -eq 3 ]
  [ ! -e "$OUT_FILE" ]
}

@test "failed jobs return exit code four" {
  export STUB_JOB_MODE=failed
  run agent code dryvist/example -p "$PROMPT_FILE" -o "$OUT_FILE"
  [ "$status" -eq 4 ]
  [ ! -e "$OUT_FILE" ]
}
