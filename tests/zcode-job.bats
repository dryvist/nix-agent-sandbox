#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
  export STUB_DIR="$BATS_TEST_TMPDIR/ssh"
  mkdir -p "$STUB_DIR"
  export ZCODE_JOB_CONFIG="$BATS_TEST_TMPDIR/config.json"
  jq -n '{sshHost: "zcode-dispatch", allowedRepos: ["dryvist/example"],
    liveUrl: "https://zcode.example.test"}' >"$ZCODE_JOB_CONFIG"
  export JOB=j-0123456789abcdef
  jq -n --arg job "$JOB" '{job: $job, tool: "zcode", repo: "dryvist/example",
    state: "succeeded", duration: 23, pr: "https://github.com/dryvist/example/pull/4"}' \
    >"$STUB_DIR/response.json"
}

client() { "$ZCODE_JOB_BIN/zcode-job" "$@"; }
no_ssh() { [ ! -e "$STUB_DIR/ssh-commands" ]; }

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

@test "repo outside the installation subset is refused before SSH" {
  run client start other/private 'Review code'
  [ "$status" -eq 64 ]
  jq -e '.error == "Repository is not approved for ZCode"' <<<"$output"
  no_ssh
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
  [ "$(jq -r '.result' <<<"$output")" = "$(printf 'job: %s\ntool: zcode\nrepo: dryvist/example\nstate: succeeded\npr: https://github.com/dryvist/example/pull/4\nduration: 23s' "$JOB")" ]
  jq '.state = "running"' "$STUB_DIR/response.json" >"$STUB_DIR/next.json"
  mv "$STUB_DIR/next.json" "$STUB_DIR/response.json"
  run client result "$JOB"
  [ "$status" -eq 1 ]
  jq -e '.error == "Job has no terminal result"' <<<"$output"
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
  jq '.repo = "other/private"' "$STUB_DIR/response.json" >"$STUB_DIR/next.json"
  mv "$STUB_DIR/next.json" "$STUB_DIR/response.json"
  rm "$STUB_DIR/ssh-commands"
  run client continue "$JOB" 'Add tests'
  [ "$status" -eq 1 ]
  [ "$(cat "$STUB_DIR/ssh-commands")" = "status $JOB" ]
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

@test "wrong job, tool, repository or PR is rejected" {
  cp "$STUB_DIR/response.json" "$STUB_DIR/original.json"
  for mutation in '.job = "j-ffffffffffffffff"' '.tool = "opencode"' \
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
