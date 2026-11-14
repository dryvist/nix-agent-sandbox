#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
  export STUB_DIR="$BATS_TEST_TMPDIR/ssh"
  mkdir -p "$STUB_DIR"
  export ZCODE_JOB_CONFIG="$BATS_TEST_TMPDIR/config.json"
  jq -n '{sshHost: "zcode-dispatch", allowedRepos: ["dryvist/example"],
    liveUrl: "https://zcode.example.test"}' >"$ZCODE_JOB_CONFIG"
  export ZCODE_JOB_JSON=1
  export UNTRUSTED_OK=public
  export JOB=j-0123456789abcdef
  jq -n --arg job "$JOB" '{job: $job, tool: "zcode", repo: "dryvist/example",
    state: "succeeded", duration: 23, pr: "https://github.com/dryvist/example/pull/4"}' \
    >"$STUB_DIR/response.json"
  # git stand-in on PATH. The visibility read runs under env -i, which strips test
  # variables, so the stub has its output directory baked in and reads its exit code
  # and stderr from files that set_git_read writes. Default: exit 0 (reachable).
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '%s\n' "#!$BASH" "stub_out=$(printf %q "$STUB_DIR")" 'set -euo pipefail' \
    'for name in GIT_TERMINAL_PROMPT GIT_ASKPASS GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS GIT_DIR; do' \
    '  printf "%s=%s\n" "$name" "${!name-unset}"' \
    'done >"$stub_out/git-env"' \
    'printf "%s\n" "$@" >"$stub_out/git-argv"' \
    'if [ -e "$stub_out/git-stderr" ]; then cat "$stub_out/git-stderr" >&2; fi' \
    'if [ -e "$stub_out/git-exit" ]; then exit "$(cat "$stub_out/git-exit")"; fi' \
    'exit 0' >"$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

client() { "$ZCODE_JOB_BIN/zcode-job" "$@"; }
no_ssh() { [ ! -e "$STUB_DIR/ssh-commands" ]; }
no_git() { [ ! -e "$STUB_DIR/git-argv" ]; }
set_git_read() { printf '%s\n' "$1" >"$STUB_DIR/git-exit"; printf '%s\n' "${2-}" >"$STUB_DIR/git-stderr"; }
marker_error='UNTRUSTED_OK=public is required: jobs run untrusted agents and may only receive public data'
sanitized_git_env=$'GIT_TERMINAL_PROMPT=0\nGIT_ASKPASS=/bin/false\nGIT_CONFIG_GLOBAL=/dev/null\nGIT_CONFIG_NOSYSTEM=1\nGIT_CONFIG_COUNT=unset\nGIT_CONFIG_KEY_0=unset\nGIT_CONFIG_VALUE_0=unset\nGIT_CONFIG_PARAMETERS=unset\nGIT_DIR=unset'

@test "help succeeds without client configuration" {
  rm "$ZCODE_JOB_CONFIG"
  run client --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: zcode-job start"* ]]
  no_ssh
}

@test "start forwards only the ZCode request with text preserved" {
  export GH_TOKEN=github-secret GITHUB_TOKEN=github-secret BAO_TOKEN=bao-secret
  export OPENBAO_APPROLE_OPEN_LLM_SECRET_ID=role-secret
  local prompt='Review $(touch /tmp/not-executed) ; `id` "quotes"'
  prompt+=$'\nnext line with unicode λ'
  run client start dryvist/example "$prompt"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/ssh-commands")" = "start zcode dryvist/example $prompt" ]
  [ "$(jq -r '.job' <<<"$output")" = "$JOB" ]
  run grep -E 'github-secret|bao-secret|role-secret' "$STUB_DIR/ssh-argv"
  [ "$status" -eq 1 ]
  for option in BatchMode=yes ForwardAgent=no ClearAllForwardings=yes 'SendEnv=-*'; do
    grep -Fx -- "$option" "$STUB_DIR/ssh-argv"
  done
}

@test "start defaults to the zcode tool" {
  run client start dryvist/example Review
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/ssh-commands")" = "start zcode dryvist/example Review" ]
}

@test "start --tool forwards the chosen tool and returns its job" {
  jq '.tool = "opencode"' "$STUB_DIR/response.json" >"$STUB_DIR/next.json"
  mv "$STUB_DIR/next.json" "$STUB_DIR/response.json"
  run client start --tool opencode dryvist/example Review
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/ssh-commands")" = "start opencode dryvist/example Review" ]
  [ "$(jq -r '.tool' <<<"$output")" = opencode ]
}

@test "unknown or incomplete --tool is refused before SSH" {
  run client start --tool claude dryvist/example Review
  [ "$status" -eq 64 ]
  jq -e '.error == "Unsupported tool"' <<<"$output"
  no_ssh
  run client start --tool
  [ "$status" -eq 64 ]
  no_ssh
  run client start --tool opencode dryvist/example
  [ "$status" -eq 64 ]
  no_ssh
}

@test "start rejects a dispatcher response for a different tool" {
  run client start --tool opencode dryvist/example Review
  [ "$status" -eq 1 ]
  jq -e '.error == "Dispatcher returned a different tool"' <<<"$output"
}

@test "status and result accept a job of any approved tool" {
  jq '.tool = "qwen-code"' "$STUB_DIR/response.json" >"$STUB_DIR/next.json"
  mv "$STUB_DIR/next.json" "$STUB_DIR/response.json"
  run client status "$JOB"
  [ "$status" -eq 0 ]
  run client result "$JOB"
  [ "$status" -eq 0 ]
  jq -e '.result | contains("tool: qwen-code")' <<<"$output"
}

@test "tool allowlist matches the dispatcher's valid_tool" {
  tools() {
    sed -n "/^$2()/,/^}/p" "$1" | sed -n 's/^ *\(.*\)) ;;$/\1/p' |
      tr -d ' ' | tr '|' '\n' | sort
  }
  local expected
  expected=$(tools "$ZCODE_JOB_SCRIPTS/agent-dispatch.sh" valid_tool)
  [ -n "$expected" ]
  [ "$(tools "$ZCODE_JOB_SCRIPTS/zcode-job.sh" tool_allowed)" = "$expected" ]
  [[ $expected == *$'\nopencode-qwen\n'* ]]
}

@test "repo outside the installation subset is refused before SSH" {
  run client start other/private 'Review code'
  [ "$status" -eq 64 ]
  jq -e '.error == "Repository is not approved for ZCode"' <<<"$output"
  no_ssh
}

@test "owner wildcard allows repositories only for its owner" {
  jq '.allowedRepos = ["dryvist/*"]' "$ZCODE_JOB_CONFIG" >"$STUB_DIR/next.json"
  mv "$STUB_DIR/next.json" "$ZCODE_JOB_CONFIG"
  run client start dryvist/example Review
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/ssh-commands")" = 'start zcode dryvist/example Review' ]
  rm -f "$STUB_DIR/ssh-commands"
  run client start JacobPEvans/example Review
  [ "$status" -eq 64 ]
  jq -e '.error == "Repository is not approved for ZCode"' <<<"$output"
  no_ssh
}

@test "owner wildcard is accepted in the configured repository patterns" {
  jq '.allowedRepos = ["dryvist/*"]' "$ZCODE_JOB_CONFIG" >"$STUB_DIR/next.json"
  mv "$STUB_DIR/next.json" "$ZCODE_JOB_CONFIG"
  run client repos
  [ "$status" -eq 0 ]
  jq -e '.repos == ["dryvist/*"]' <<<"$output"
}

@test "malformed inputs and control characters are refused before SSH" {
  for repo in dryvist/.. dryvist/. dryvist/example/extra 'dryvist/example;id'; do
    run client start "$repo" 'Review'
    [ "$status" -eq 64 ]
    no_ssh
  done
  run client continue invalid 'Review'
  [ "$status" -eq 64 ]
  no_ssh
  run client start dryvist/example $'Review\001'
  [ "$status" -eq 64 ]
  no_ssh
  run client start dryvist/example "$(head -c 16385 /dev/zero | tr '\0' a)"
  [ "$status" -eq 64 ]
  no_ssh
}

@test "missing or malformed configuration fails closed" {
  rm "$ZCODE_JOB_CONFIG"
  run client start dryvist/example Review
  [ "$status" -eq 64 ]
  no_ssh
  jq -n '{sshHost: "-proxy", allowedRepos: [], liveUrl: "http://unsafe"}' >"$ZCODE_JOB_CONFIG"
  run client start dryvist/example Review
  [ "$status" -eq 64 ]
  no_ssh
}

@test "status and fixed terminal result are JSON" {
  run client status "$JOB"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = succeeded ]
  run client result "$JOB"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.result' <<<"$output")" = "$(printf 'job: %s\ntool: zcode\nrepo: dryvist/example\nstate: succeeded\npr: https://github.com/dryvist/example/pull/4\nduration: 23s\noutput:' "$JOB")" ]
  jq '.state = "running"' "$STUB_DIR/response.json" >"$STUB_DIR/next.json"
  mv "$STUB_DIR/next.json" "$STUB_DIR/response.json"
  run client result "$JOB"
  [ "$status" -eq 1 ]
  jq -e '.error == "Job has no terminal result"' <<<"$output"
}

@test "successful result appends the dispatcher output tail" {
  jq '.output = "review complete\nsecond useful line\n"' "$STUB_DIR/response.json" >"$STUB_DIR/next.json"
  mv "$STUB_DIR/next.json" "$STUB_DIR/response.json"
  run client result "$JOB"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.result' <<<"$output")" = "$(printf 'job: %s\ntool: zcode\nrepo: dryvist/example\nstate: succeeded\npr: https://github.com/dryvist/example/pull/4\nduration: 23s\noutput:\nreview complete\nsecond useful line' "$JOB")" ]
}

@test "result --output writes only the output text to the file" {
  jq '.output = "answer line one\nanswer line two\n"' "$STUB_DIR/response.json" >"$STUB_DIR/next.json"
  mv "$STUB_DIR/next.json" "$STUB_DIR/response.json"
  run client result "$JOB" --output "$BATS_TEST_TMPDIR/answer.txt"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/answer.txt")" = "$(printf 'answer line one\nanswer line two')" ]
  run client result "$JOB" --bogus "$BATS_TEST_TMPDIR/x"
  [ "$status" -ne 0 ]
}

@test "failed result appends the output tail and failure reason" {
  jq '.state = "failed" | .reason = "exit 1" | .output = "compiler failed\nlast diagnostic\n"' \
    "$STUB_DIR/response.json" >"$STUB_DIR/next.json"
  mv "$STUB_DIR/next.json" "$STUB_DIR/response.json"
  run client result "$JOB"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.result' <<<"$output")" = "$(printf 'job: %s\ntool: zcode\nrepo: dryvist/example\nstate: failed\npr: https://github.com/dryvist/example/pull/4\nduration: 23s\noutput:\ncompiler failed\nlast diagnostic\nreason: exit 1' "$JOB")" ]
}

@test "continue and cancel scope-check the job before mutation" {
  run client continue "$JOB" 'Add tests'
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/ssh-commands")" = "$(printf 'status %s\ncontinue %s Add tests' "$JOB" "$JOB")" ]
  rm "$STUB_DIR/ssh-commands"
  run client cancel "$JOB"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = cancelling ]
  [ "$(cat "$STUB_DIR/ssh-commands")" = "$(printf 'status %s\ncancel %s' "$JOB" "$JOB")" ]
}

@test "transport and malformed response failures produce JSON errors" {
  export STUB_SSH_EXIT=255
  run client status "$JOB"
  [ "$status" -eq 255 ]
  jq -e '.error == "Dispatcher SSH request failed"' <<<"$output"
  unset STUB_SSH_EXIT
  printf '%s\n' 'garbage' >"$STUB_DIR/response.json"
  run client status "$JOB"
  [ "$status" -eq 1 ]
  jq -e '.error == "Invalid dispatcher JSON"' <<<"$output"
}

@test "a refused continue reports the dispatcher's own reason" {
  export STUB_SSH_EXIT=64 STUB_SSH_FAIL_ON=continue
  printf '%s\n' 'agent-dispatch: job token is unavailable; start a new job' >"$STUB_DIR/ssh-stderr"
  run --separate-stderr client continue "$JOB" 'Add tests'
  [ "$status" -eq 64 ]
  jq -e '.error == "dispatcher refused" and
    .reason == "job token is unavailable; start a new job"' <<<"$output"
  [[ -z "$stderr" ]]
  [ "$(cat "$STUB_DIR/ssh-commands")" = "$(printf 'status %s\ncontinue %s Add tests' "$JOB" "$JOB")" ]
  unset ZCODE_JOB_JSON
  run --separate-stderr client continue "$JOB" 'Add tests'
  [ "$status" -eq 64 ]
  jq -e '.error == "dispatcher refused" and
    .reason == "job token is unavailable; start a new job"' <<<"$output"
  [ "$stderr" = "agent-dispatch: job token is unavailable; start a new job" ]
}

@test "a failure without a refusal line keeps the transport error" {
  export STUB_SSH_EXIT=255
  printf '%s\n' 'ssh: connection timed out' >"$STUB_DIR/ssh-stderr"
  run --separate-stderr client status "$JOB"
  [ "$status" -eq 255 ]
  jq -e '.error == "Dispatcher SSH request failed"' <<<"$output"
  [ "$stderr" = "ssh: connection timed out" ]
}

@test "a refusal reason with quotes and backslashes stays valid JSON" {
  local filler
  filler=$(printf 'a%.0s' $(seq 1 320))
  export STUB_SSH_EXIT=64 STUB_SSH_FAIL_ON=continue
  printf '%s\n' "agent-dispatch: bad \"quote\" and \\ flag ${filler} TAIL" >"$STUB_DIR/ssh-stderr"
  run client continue "$JOB" 'Add tests'
  [ "$status" -eq 64 ]
  jq -e --arg prefix 'bad "quote" and \ flag ' \
    '.error == "dispatcher refused" and (.reason | length) == 300 and
    (.reason | startswith($prefix))' <<<"$output"
}

@test "wrong job, tool, repository or PR is rejected" {
  cp "$STUB_DIR/response.json" "$STUB_DIR/original.json"
  for mutation in '.job = "j-ffffffffffffffff"' '.tool = "claude"' \
    '.pr = "https://github.com/other/private/pull/4"' '.duration = -1'; do
    jq "$mutation" "$STUB_DIR/original.json" >"$STUB_DIR/next.json"
    mv "$STUB_DIR/next.json" "$STUB_DIR/response.json"
    run client status "$JOB"
    [ "$status" -eq 1 ]
  done
  jq -n --arg job "$JOB" '{job: $job, tool: "zcode", repo: "other/private",
    state: "running", duration: 0, pr: ""}' >"$STUB_DIR/response.json"
  run client start dryvist/example Review
  [ "$status" -eq 1 ]
}

@test "empty PR has the fixed none value and extra response fields are omitted" {
  jq '.pr = "" | .web_token = "must-not-print"' "$STUB_DIR/response.json" >"$STUB_DIR/next.json"
  mv "$STUB_DIR/next.json" "$STUB_DIR/response.json"
  run client result "$JOB"
  [ "$status" -eq 0 ]
  jq -e '.result | contains("pr: none")' <<<"$output"
  [[ $output != *must-not-print* ]]
}

@test "startup failure keeps the validated job id and failure status" {
  jq '.state = "failed" | .reason = "mint refused"' "$STUB_DIR/response.json" >"$STUB_DIR/next.json"
  mv "$STUB_DIR/next.json" "$STUB_DIR/response.json"
  export STUB_SSH_EXIT=1 STUB_RESPONSE_ON_ERROR=1
  run client start dryvist/example Review
  [ "$status" -eq 1 ]
  jq -e --arg job "$JOB" '.job == $job and .state == "failed" and .reason == "mint refused"' <<<"$output"
}

@test "a failed start cannot return a different approved repository" {
  jq '.allowedRepos += ["dryvist/another"]' "$ZCODE_JOB_CONFIG" >"$STUB_DIR/config-next.json"
  mv "$STUB_DIR/config-next.json" "$ZCODE_JOB_CONFIG"
  jq '.state = "failed" | .repo = "dryvist/another" | .pr = ""' "$STUB_DIR/response.json" >"$STUB_DIR/next.json"
  mv "$STUB_DIR/next.json" "$STUB_DIR/response.json"
  export STUB_SSH_EXIT=1 STUB_RESPONSE_ON_ERROR=1
  run client start dryvist/example Review
  [ "$status" -eq 1 ]
  jq -e '.error == "Dispatcher returned a different repository"' <<<"$output"
}

@test "live returns the native SSO session URL without SSH" {
  run client live
  [ "$status" -eq 0 ]
  jq -e '.url == "https://zcode.example.test" and .surface == "zcode-web-server"' <<<"$output"
  no_ssh
}

@test "repos lists the approved subset without SSH" {
  run client repos
  [ "$status" -eq 0 ]
  jq -e '.repos == ["dryvist/example"]' <<<"$output"
  no_ssh
}

@test "start waits and prints DONE with a PR or no-pr" {
  jq '.output = "completed agent output"' "$STUB_DIR/response.json" >"$STUB_DIR/next.json"
  mv "$STUB_DIR/next.json" "$STUB_DIR/response.json"
  unset ZCODE_JOB_JSON
  run client start dryvist/example Review
  [ "$status" -eq 0 ]
  [ "$output" = "DONE|$JOB|https://github.com/dryvist/example/pull/4" ]
  grep -Fx "status $JOB" "$STUB_DIR/ssh-commands"
  jq '.pr = ""' "$STUB_DIR/response.json" >"$STUB_DIR/next.json"
  mv "$STUB_DIR/next.json" "$STUB_DIR/response.json"
  run client continue "$JOB" Review
  [ "$status" -eq 0 ]
  [ "$output" = "DONE|$JOB|no-pr" ]
}

@test "terminal failure prints a single stripped reason" {
  unset ZCODE_JOB_JSON
  jq '.state = "failed" | .reason = "first\nsecond" | .output = "failure details"' \
    "$STUB_DIR/response.json" >"$STUB_DIR/next.json"
  mv "$STUB_DIR/next.json" "$STUB_DIR/response.json"
  run client start dryvist/example Review
  [ "$status" -eq 1 ]
  [ "$output" = "FAIL|$JOB|firstsecond" ]
}

@test "wait timeout leaves the job running" {
  unset ZCODE_JOB_JSON
  export ZCODE_JOB_WAIT=1
  jq '.state = "running"' "$STUB_DIR/response.json" >"$STUB_DIR/next.json"
  mv "$STUB_DIR/next.json" "$STUB_DIR/response.json"
  run client start dryvist/example Review
  [ "$status" -eq 1 ]
  [ "$output" = "FAIL|$JOB|timeout" ]
  ! grep -q '^cancel ' "$STUB_DIR/ssh-commands"
}

@test "JSON opt-out returns the submission without polling" {
  run client start dryvist/example Review
  [ "$status" -eq 0 ]
  jq -e --arg job "$JOB" '.job == $job' <<<"$output"
  ! grep -q '^status ' "$STUB_DIR/ssh-commands"
}

@test "start requires the public marker before any lookup or SSH" {
  unset UNTRUSTED_OK
  run client start dryvist/example Review
  [ "$status" -eq 64 ]
  jq -e --arg error "$marker_error" '.error == $error' <<<"$output"
  no_ssh
  no_git
  export UNTRUSTED_OK=Public
  run client start dryvist/example Review
  [ "$status" -eq 64 ]
  no_ssh
}

@test "continue requires the public marker before SSH" {
  unset UNTRUSTED_OK
  run client continue "$JOB" 'Add tests'
  [ "$status" -eq 64 ]
  jq -e --arg error "$marker_error" '.error == $error' <<<"$output"
  no_ssh
}

@test "start refuses a repository that is not verifiably public" {
  set_git_read 128 "fatal: could not read Username for 'https://github.com': terminal prompts disabled"
  run client start dryvist/example Review
  [ "$status" -eq 64 ]
  jq -e '.error == "repository is not verifiably public: dryvist/example"' <<<"$output"
  no_ssh
}

@test "opencode-qwen refuses a repository that is not verifiably public" {
  set_git_read 128 "fatal: repository not found"
  run client start --tool opencode-qwen dryvist/example Review
  [ "$status" -eq 64 ]
  jq -e '.error == "repository is not verifiably public: dryvist/example"' <<<"$output"
  no_ssh
}

@test "continue refuses a job whose repository is not verifiably public" {
  set_git_read 128
  run client continue "$JOB" 'Add tests'
  [ "$status" -eq 64 ]
  jq -e '.error == "repository is not verifiably public: dryvist/example"' <<<"$output"
  [ "$(cat "$STUB_DIR/ssh-commands")" = "status $JOB" ]
}

@test "visibility check allows a repo that the anonymous git read can reach" {
  run client start dryvist/example Review
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/ssh-commands")" = "start zcode dryvist/example Review" ]
  [ "$(cat "$STUB_DIR/git-env")" = "$sanitized_git_env" ]
  [ "$(cat "$STUB_DIR/git-argv")" = $'-c\ncredential.helper=\nls-remote\n--exit-code\nhttps://github.com/dryvist/example\nHEAD' ]
}

@test "visibility check ignores environment-injected git config" {
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="Authorization: injected"
  export GIT_CONFIG_PARAMETERS="'credential.helper=echo injected'" GIT_DIR="$BATS_TEST_TMPDIR/not-a-repo"
  run client start dryvist/example Review
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/git-env")" = "$sanitized_git_env" ]
}

@test "visibility check refuses a repo that does not exist" {
  set_git_read 128 $'remote: Repository not found.\nfatal: repository not found'
  run client start dryvist/example Review
  [ "$status" -eq 64 ]
  jq -e '.error == "repository is not verifiably public: dryvist/example"' <<<"$output"
  no_ssh
}

@test "visibility check refuses when the lookup fails" {
  set_git_read 128 "fatal: unable to access 'https://github.com/dryvist/example/': Could not resolve host: github.com"
  run client start dryvist/example Review
  [ "$status" -eq 64 ]
  jq -e '.error == "repository is not verifiably public: dryvist/example"' <<<"$output"
  no_ssh
}

@test "visibility check refuses every non-zero exit of the git read" {
  local code
  for code in $(seq 1 255); do
    set_git_read "$code"
    run client start dryvist/example Review
    [ "$status" -eq 64 ]
    jq -e '.error == "repository is not verifiably public: dryvist/example"' <<<"$output"
  done
  no_ssh
}

@test "status, live and repos work without the public marker" {
  unset UNTRUSTED_OK
  run client status "$JOB"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = succeeded ]
  no_git
  run client live
  [ "$status" -eq 0 ]
  run client repos
  [ "$status" -eq 0 ]
}
