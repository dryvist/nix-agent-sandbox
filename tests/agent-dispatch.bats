#!/usr/bin/env bats
# agent-dispatch and dispatch-ssh: argument validation, docker arguments,
# credential delivery, fail-closed minting and the fixed-format result.
# docker, curl and setsid are stubs (tests/stubs); no test reaches a live
# service.
#
# AGENT_DISPATCH_BIN is the built package's bin dir (the flake check sets
# it); ENTRYPOINT is scripts/entrypoint.sh.

bats_require_minimum_version 1.5.0

SECRETS=(role-id-value secret-id-value zai-secret-value
  zcode-router-secret-value opencode-router-secret-value cursor-router-secret-value
  cursor-secret-value qwen-code-router-secret-value vikunja-secret-value zammad-secret-value
  sandbox-router-secret-value sandbox-agent-role-id-value sandbox-agent-wrapped-id-value
  splunk-search-secret-value ntfy-secret-value ntfy-alert-token ghs_minted_secret s.tok)

setup() {
  export BATS_TEST_DIRNAME
  : "${AGENT_DISPATCH_BIN:?set AGENT_DISPATCH_BIN to the agent-dispatch bin dir}"
  export STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  : >"$STUB_DIR/argv.log"
  : >"$STUB_DIR/calls.log"
  cp "$BATS_TEST_DIRNAME/fixtures/bucket.json" "$STUB_DIR/"
  export REAL_GIT="$(command -v git)"
  unset STUB_FIX_DIR STUB_FIX_CONTAINERS STUB_FIX_RUNNING_COUNT STUB_FIX_BRANCH_EXISTS \
    STUB_CONTENTS_404 STUB_BASE_CONTENT STUB_BASE_TOO_LARGE STUB_HEAD_MOVED STUB_DEFAULT_BRANCH \
    STUB_FIX_PR_URL STUB_DOCKER_LOG_FILE STUB_EXIT STUB_SCOPE_REPO
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
  export AGENT_DISPATCH_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export AGENT_DISPATCH_APPROLE_DIR="$BATS_TEST_TMPDIR/approle"
  mkdir -p "$AGENT_DISPATCH_APPROLE_DIR"
  printf 'role-id-value\n' >"$AGENT_DISPATCH_APPROLE_DIR/role_id"
  printf 'secret-id-value\n' >"$AGENT_DISPATCH_APPROLE_DIR/secret_id"
  chmod 0400 "$AGENT_DISPATCH_APPROLE_DIR/role_id" "$AGENT_DISPATCH_APPROLE_DIR/secret_id"
  export BAO_ADDR=https://bao.test
  export AGENT_ROUTER_BASE_URL=https://router.test/v1
  export GIT_MIRROR_URL=https://mirror.test/public
  export VIKUNJA_URL=https://vikunja.test/api/v1
  export ZAMMAD_URL=https://zammad.test/api/v1
  export AGENT_DISPATCH_NTFY_ALERT_URL=https://ntfy.test
  export AGENT_DISPATCH_NTFY_ALERT_TOKEN=ntfy-alert-token
  export AGENT_DISPATCH_VIKUNJA_PROJECT=55
  export AGENT_REPO_DENYLIST=blocked-owner
}


dispatch() { "$AGENT_DISPATCH_BIN/agent-dispatch" "$@"; }
ssh_cmd() { SSH_ORIGINAL_COMMAND="$1" "$AGENT_DISPATCH_BIN/dispatch-ssh"; }
# make_dispatcher <profiles-json>: a copy of agent-dispatch whose task profiles
# are the given JSON; prints its path.
make_dispatcher() {
  local bin="$BATS_TEST_TMPDIR/profile-bin" line
  mkdir -p "$bin"
  while IFS= read -r line; do
    if [[ $line == AGENT_TASK_PROFILES=* ]]; then
      printf '%s\n' "AGENT_TASK_PROFILES='$1'"
    else
      printf '%s\n' "$line"
    fi
  done <"$AGENT_DISPATCH_BIN/agent-dispatch" >"$bin/agent-dispatch"
  chmod +x "$bin/agent-dispatch"
  printf '%s\n' "$bin/agent-dispatch"
}
bash_stub() {
  { printf '#!%s\n' "$BASH"; cat; } >"$1"
  chmod +x "$1"
}

# create_args <n>: the n-th `docker create` argument list, into $a.
create_args() { mapfile -t a <"$STUB_DIR/create.$1"; }

has_pair() {
  local i
  for ((i = 0; i < ${#a[@]} - 1; i++)); do
    if [ "${a[i]}" = "$1" ] && [ "${a[i + 1]}" = "$2" ]; then return 0; fi
  done
  echo "missing: $1 $2" >&2
  return 1
}

no_secret_on_a_command_line() {
  local s
  for s in "${SECRETS[@]}"; do
    if grep -qF -- "$s" "$STUB_DIR/argv.log"; then
      echo "a test credential appeared on a command line" >&2
      return 1
    fi
  done
}

# http_rec <method url>: the stub record prefix of the last such request.
http_rec() {
  local f last=""
  for f in "$STUB_DIR"/http.*.req; do
    if [ "$(cat "$f")" = "$1" ]; then last=${f%.req}; fi
  done
  [ -n "$last" ] || {
    echo "no request: $1" >&2
    return 1
  }
  echo "$last"
}

line_of() { grep -nF -- "$1" "$STUB_DIR/calls.log" | head -n 1 | cut -d: -f1; }
last_line_of() { grep -nF -- "$1" "$STUB_DIR/calls.log" | tail -n 1 | cut -d: -f1; }
fix_prompt() { printf 'CI-RESOLVER headline=fix%%3A%%20repair%%20test attempt=2 tier=t2 signature=abcdef012345\n%s' "$1"; }
fix_prompt_tier() { printf 'CI-RESOLVER headline=fix%%3A%%20repair%%20test attempt=2 tier=%s signature=abcdef012345\n%s' "$1" "$2"; }
fix_add_json() {
  local encoded
  encoded=$(printf '%s' "$2" | base64 | tr -d '\n')
  jq -cn --arg p "$1" --arg c "$encoded" '{additions: [{path: $p, contents: $c}], deletions: []}'
}
fix_delete_json() { jq -cn --arg p "$1" '{additions: [], deletions: [{path: $p}]}' ; }
set_fix_outputs() {
  export STUB_FIX_DIR="$STUB_DIR/fix/.agent-fix"
  mkdir -p "$STUB_FIX_DIR"
  printf '%s\n' "$1" >"$STUB_FIX_DIR/changes.json"
  : >"$STUB_FIX_DIR/patch.diff"
  : >"$STUB_FIX_DIR/summary.txt"
}
fix_dispatch() {
  local prompt
  prompt=$(fix_prompt "${1:-repair this failure}")
  run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
}

FIX_SHA=0123456789abcdef0123456789abcdef01234567

@test "dispatch-ssh refuses hostile or malformed commands before any side effect" {
  local long c
  long=$(head -c 16385 /dev/zero | tr '\0' a)
  local cmds=(
    ""
    "rm -rf /"
    "__wait j-0123456789abcdef 1"
    "__job j-0123456789abcdef 1"
    "STATUS j-0123456789abcdef"
    "start"
    "start zcode"
    "start zcode dryvist/nix-ai"
    "start bash dryvist/nix-ai do it"
    "start zcode dryvist/nix-ai;id do it"
    "start zcode dryvist/nix-ai|id do it"
    "start zcode dryvist/nix-ai\$(id) do it"
    "start zcode dryvist/nix-ai\`id\` do it"
    "start zcode ../../etc/passwd do it"
    "start zcode dryvist/.. do it"
    "start zcode dryvist/. do it"
    "start zcode -rf/nix-ai do it"
    "start zcode dryvist/nix-ai/extra do it"
    "start zcode dryvist do it"
    "start --interactive cursor-agent dryvist/nix-ai do it"
    "start --interactive"
    "start --interactive zcode dryvist/nix-ai do it"
    "fix -tool dryvist/nix-ai ci/fix 0123456789abcdef0123456789abcdef01234567 task"
    "start --tty zcode dryvist/nix-ai"
    "tty zcode dryvist/nix-ai"
    "tty"
    "start zcode dryvist/nix-ai $long"
    "start zcode dryvist/nix-ai $(printf 'colour \033[31m red')"
    "start zcode dryvist/nix-ai $(printf 'carriage\rreturn')"
    "status"
    "status ../../../etc/passwd"
    "status j-0123456789abcdeg"
    "status J-0123456789ABCDEF"
    "status j-0123456789abcdef0"
    "status j-0123456789abcdef extra"
    "status j-0123456789abcdef;id"
    "cancel"
    "cancel j-0123456789abcdef j-0123456789abcdef"
    "continue j-0123456789abcdef"
    "continue ../x message"
    "refresh now"
    "refresh;id"
  )
  for c in "${cmds[@]}"; do
    run ssh_cmd "$c"
    if [ "$status" -ne 64 ]; then
      echo "accepted (status $status): ${c:0:80}" >&2
      return 1
    fi
  done
  [ ! -s "$STUB_DIR/argv.log" ]
  [ ! -e "$AGENT_DISPATCH_STATE_DIR" ]
}

@test "fix validates tool, branch, sha and metadata; start refuses the header" {
  local prompt branch
  prompt=$(fix_prompt "repair this failure")
  run --separate-stderr dispatch fix -tool dryvist/nix-ai ci/fix "$FIX_SHA" "$prompt"
  [ "$status" -eq 64 ]
  for branch in 'ci..fix' '-ci/fix' '/ci/fix' 'ci/fix/' 'ci/fix.lock' 'ci//fix'; do
    run --separate-stderr dispatch fix zcode dryvist/nix-ai "$branch" "$FIX_SHA" "$prompt"
    [ "$status" -eq 64 ]
  done
  run --separate-stderr dispatch fix zcode dryvist/nix-ai ci/fix "${FIX_SHA^^}" "$prompt"
  [ "$status" -eq 64 ]
  run --separate-stderr dispatch fix zcode dryvist/nix-ai ci/fix "$FIX_SHA" 'CI-RESOLVER headline=fix attempt=2 tier=t2 signature=bad\nrepair this failure'
  [ "$status" -eq 64 ]
  run --separate-stderr dispatch start zcode dryvist/nix-ai "$prompt"
  [ "$status" -eq 64 ]
  [[ $stderr == *"CI-RESOLVER header requires fix"* ]]
  run --separate-stderr dispatch start shell dryvist/nix-ai "repair this failure"
  [ "$status" -eq 64 ]
  [[ $stderr == *"unknown tool"* ]]
  [ ! -e "$AGENT_DISPATCH_STATE_DIR" ]
  [ ! -s "$STUB_DIR/argv.log" ]
}

@test "fix CI-RESOLVER tier binds t1 to shell in both directions" {
  local prompt
  prompt=$(fix_prompt_tier t2 'echo fixed')
  run --separate-stderr dispatch fix shell dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
  [ "$status" -eq 64 ]
  [[ $stderr == *"invalid CI-RESOLVER header"* ]]
  [ ! -e "$AGENT_DISPATCH_STATE_DIR" ]

  prompt=$(fix_prompt_tier t1 'repair this failure')
  run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
  [ "$status" -eq 64 ]
  [[ $stderr == *"invalid CI-RESOLVER header"* ]]
  [ ! -e "$AGENT_DISPATCH_STATE_DIR" ]
  [ "$(grep -c 'docker ps' "$STUB_DIR/argv.log" || true)" -eq 0 ]
}

@test "dispatch-ssh passes fix metadata and task text as separate words" {
  local prompt
  prompt=$(fix_prompt 'repair $(literal)')
  run --separate-stderr ssh_cmd "fix zcode dryvist/nix-ai ci/ssh-fix $FIX_SHA $prompt"
  [ "$status" -eq 0 ]
  [ "$(jq -r .mode <<<"$output")" = fix ]
  [ "$(jq -r .expected_sha <<<"$output")" = "$FIX_SHA" ]
  [ "$(tar -xOf "$STUB_DIR/cp.1.tar" .agent-prompt)" = 'repair $(literal)' ]
  [ "$(cat "$AGENT_DISPATCH_STATE_DIR/$(jq -r .job <<<"$output")/runs/1/state")" = no-change ]
}

@test "the prompt reaches the container verbatim; metacharacters are data" {
  local prompt="fix \$(touch $BATS_TEST_TMPDIR/pwned) \`touch $BATS_TEST_TMPDIR/pwned\`; rm -rf / && echo \"x\" | cat > ../../y — café"
  run --separate-stderr ssh_cmd "start zcode dryvist/nix-ai $prompt"
  [ "$status" -eq 0 ]
  [ "$(tar -xOf "$STUB_DIR/cp.1.tar" .agent-prompt)" = "$prompt" ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "the container gets no service credentials in env args, no host path, no socket" {
  local id i mounts=()
  run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  [ "$status" -eq 0 ]
  id=$(jq -r .job <<<"$output")
  create_args 1
  for ((i = 0; i < ${#a[@]}; i++)); do
    case "${a[i]}" in
      -e)
        case "${a[i + 1]%%=*}" in
          HTTP_PROXY | HTTPS_PROXY | http_proxy | https_proxy | AGENT_TOOL | AGENT_PROFILE | \
            AGENT_DISPATCHED_JOB | AGENT_REPO | AGENT_RUN_ID | AGENT_PR_DRAFT | \
            AGENT_CONTINUE | AGENT_TTY) ;;
          *)
            echo "unexpected -e ${a[i + 1]%%=*}" >&2
            return 1
            ;;
        esac
        ;;
      -v | --volume) mounts+=("${a[i + 1]}") ;;
      --mount | --privileged | --pid | --ipc | --userns | --cap-add | --device | --volumes-from | \
        --env | --env-file | --network=host | --net)
        echo "forbidden ${a[i]}" >&2
        return 1
        ;;
    esac
  done
  [ "${#mounts[@]}" -eq 1 ]
  [ "${mounts[0]}" = "agent-job-$id:/home/agent/work" ]
  run ! grep -Eiq 'bao|vault|openbao|role_id|secret_id|docker\.sock' "$STUB_DIR/create.1"
  has_pair --network agents
  has_pair --cap-drop ALL
  has_pair --security-opt no-new-privileges
  has_pair -e AGENT_PROFILE=zcode
  has_pair -e AGENT_DISPATCHED_JOB=1
  has_pair -e AGENT_PR_DRAFT=1
  has_pair -e HTTPS_PROXY=http://proxy:3128
  no_secret_on_a_command_line
}

@test "sandbox credentials and profile values arrive in a mode-0600 env file" {
  local env_data rec
  run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  [ "$status" -eq 0 ]
  env_data=$(tar -xOf "$STUB_DIR/cp.1.tar" .agent-env)
  [ "$(printf '%s\n' "$env_data" | cut -d= -f1 | sort)" = "$(printf '%s\n' \
    AGENT_ROUTER_BASE_URL BAO_ADDR GIT_MIRROR_URL GH_TOKEN GITHUB_TOKEN SANDBOX_ROLE_ID \
    SANDBOX_WRAPPED_SECRET_ID VIKUNJA_URL ZAMMAD_URL | sort)" ]
  grep -qx 'BAO_ADDR=https://bao.test' <<<"$env_data"
  grep -qx 'SANDBOX_ROLE_ID=sandbox-agent-role-id-value' <<<"$env_data"
  grep -qx 'SANDBOX_WRAPPED_SECRET_ID=sandbox-agent-wrapped-id-value' <<<"$env_data"
  grep -qx 'GIT_MIRROR_URL=https://mirror.test/public' <<<"$env_data"
  [[ ! $env_data =~ AGENT_ROUTER_KEY|OPENBAO_APPROLE|s\.tok ]]
  grep -q 'GET https://bao.test/v1/auth/approle/role/sandbox-agent-write/role-id' "$STUB_DIR/calls.log"
  rec=$(http_rec "POST https://bao.test/v1/auth/approle/role/sandbox-agent-write/secret-id")
  grep -qx 'X-Vault-Wrap-TTL: 15m' "$rec.hdr"
  [ "$(tar -tvf "$STUB_DIR/cp.1.tar" | grep -c -- '^-rw------- 1000/1000 ')" -eq 2 ]
  [ "$(line_of 'docker create')" -lt "$(line_of 'docker cp')" ]
  [ "$(line_of 'docker cp')" -lt "$(line_of 'docker start')" ]
  grep -q '^setsid -f .*agent-dispatch __job j-[0-9a-f]\{16\} 1$' "$STUB_DIR/argv.log"
  no_secret_on_a_command_line
}

@test "the host reads the external plan key and delivers only the selected profile field" {
  local env_data
  run --separate-stderr dispatch start opencode-zai dryvist/nix-ai "do the thing"
  [ "$status" -eq 0 ]
  env_data=$(tar -xOf "$STUB_DIR/cp.1.tar" .agent-env)
  grep -q '^ZAI_SUBSCRIPTION_KEY=' <<<"$env_data"
  grep -q 'GET https://bao.test/v1/secret/data/secrets-external/zai-coding' "$STUB_DIR/calls.log"
  [[ $output != *zai-secret-value* ]]
  no_secret_on_a_command_line
}

@test "profiles without routerKeyField receive neither router variable" {
  local dispatcher env_data
  dispatcher=$(make_dispatcher '{"zcode":{"env":[],"ttyLogin":true}}')
  run --separate-stderr "$dispatcher" start --tty zcode dryvist/nix-ai
  [ "$status" -eq 0 ]
  env_data=$(tar -xOf "$STUB_DIR/cp.1.tar" .agent-env)
  [[ ! $env_data =~ AGENT_ROUTER_BASE_URL|AGENT_ROUTER_KEY ]]
  [ "$(printf '%s\n' "$env_data" | cut -d= -f1 | sort)" = "$(printf '%s\n' \
    BAO_ADDR GIT_MIRROR_URL GH_TOKEN GITHUB_TOKEN SANDBOX_ROLE_ID SANDBOX_WRAPPED_SECRET_ID \
    VIKUNJA_URL ZAMMAD_URL | sort)" ]
}

@test "each routed profile receives the router endpoint and wrapped sandbox identity" {
  local tool n=0 env_data
  for tool in zcode opencode opencode-local qwen-code; do
    n=$((n + 1))
    run --separate-stderr dispatch start "$tool" dryvist/nix-ai "do the thing"
    [ "$status" -eq 0 ]
    env_data=$(tar -xOf "$STUB_DIR/cp.$n.tar" .agent-env)
    grep -qx 'AGENT_ROUTER_BASE_URL=https://router.test/v1' <<<"$env_data"
    grep -qx 'SANDBOX_WRAPPED_SECRET_ID=sandbox-agent-wrapped-id-value' <<<"$env_data"
    [[ ! $env_data =~ AGENT_ROUTER_KEY|ZAI_SUBSCRIPTION_KEY|CURSOR_API_KEY ]]
    [ "$(printf '%s\n' "$env_data" | cut -d= -f1 | sort)" = "$(printf '%s\n' \
      AGENT_ROUTER_BASE_URL BAO_ADDR GIT_MIRROR_URL GH_TOKEN GITHUB_TOKEN SANDBOX_ROLE_ID \
      SANDBOX_WRAPPED_SECRET_ID VIKUNJA_URL ZAMMAD_URL | sort)" ]
  done
}

@test "OpenCode batch profiles configure the router and fix profiles configure their models" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/opencode-fix-home" tools="$BATS_TEST_TMPDIR/opencode-fix-tools"
  mkdir -p "$home" "$tools"
  printf '%s\n' '{"opencode-local":{"env":[],"routerKeyField":"OPENCODE_ROUTER_KEY"},"opencode-zai":{"env":["ZAI_SUBSCRIPTION_KEY"]}}' \
    >"$home/.agent-profiles.json"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  bash_stub "$tools/opencode" <<'SH'
printf '%s\n' "$@" >"$STUB_DIR/opencode-fix-argv"
printf '%s\n' "${ZHIPU_API_KEY:-unset}" >"$STUB_DIR/opencode-fix-zai-key"
cp "$HOME/.config/opencode/opencode.json" "$STUB_DIR/opencode-fix-config" 2>/dev/null || true
SH
  printf '%s\n' 'AGENT_ROUTER_BASE_URL=https://router.test/v1' \
    'AGENT_ROUTER_KEY=router-test-key' >"$home/.agent-env"
  run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$STUB_DIR" AGENT_SANDBOX=1 \
    AGENT_TOOL=opencode-local AGENT_PROMPT='router prompt' bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/opencode-fix-argv")" = $'run\n--auto\n--model\nagent-router/medium\nrouter prompt' ]
  jq -e '.provider | keys == ["agent-router"] and
    .["agent-router"].npm == "@ai-sdk/openai-compatible" and
    .["agent-router"].options.baseURL == "https://router.test/v1" and
    .["agent-router"].options.apiKey == "router-test-key" and
    (.["agent-router"].models | keys == ["medium", "small"])' \
    "$home/.config/opencode/opencode.json"
  jq -e '.model == "agent-router/medium" and
    .small_model == "agent-router/small"' "$home/.config/opencode/opencode.json"
  [ "$(ls -l "$home/.config/opencode/opencode.json" | cut -c2-10)" = rw------- ]

  printf '%s\n' 'ZAI_SUBSCRIPTION_KEY=zai-plan-key' >"$home/.agent-env"
  run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$STUB_DIR" AGENT_SANDBOX=1 \
    AGENT_TOOL=opencode-zai AGENT_PROMPT='zai prompt' bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/opencode-fix-argv")" = $'run\n--auto\n--model\nzai-coding-plan/glm-5.3\nzai prompt' ]
  [ "$(cat "$STUB_DIR/opencode-fix-zai-key")" = zai-plan-key ]
}

@test "the GitHub token is minted for one repo with contents and pull_requests only" {
  local rec
  run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  [ "$status" -eq 0 ]
  rec=$(http_rec "POST https://bao.test/v1/auth/approle/login")
  [ "$(jq -cS . "$rec.body")" = '{"role_id":"role-id-value","secret_id":"secret-id-value"}' ]
  rec=$(http_rec "POST https://bao.test/v1/github-agents/token")
  [ "$(jq -cS . "$rec.body")" = '{"installation_id":"4242","permissions":{"contents":"write","pull_requests":"write"},"repositories":"nix-ai"}' ]
  grep -qx 'X-Vault-Token: s.tok1' "$rec.hdr"
  rec=$(http_rec "GET https://api.github.com/installation/repositories")
  grep -qx 'Authorization: Bearer ghs_minted_secret' "$rec.hdr"
}

@test "a refused mint fails closed without another login: no container and result posted" {
  local rec
  export STUB_MINT_FAIL=1
  run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  [ "$status" -eq 1 ]
  [ "$(jq -r .state <<<"$output")" = failed ]
  [ "$(jq -r .reason <<<"$output")" = "github token mint refused for dryvist/nix-ai" ]
  run ! grep -q '^docker' "$STUB_DIR/calls.log"
  [ "$(grep -c 'POST https://bao.test/v1/auth/approle/login' "$STUB_DIR/calls.log")" -eq 1 ]
  rec=$(http_rec "POST https://ntfy.test/ai-jobs")
  grep -qx 'state: failed' "$rec.body"
}

# scope_refused <token's repo> <token's repo count> <requested repo>
scope_refused() {
  local out rc=0
  out=$(STUB_SCOPE_REPO=$1 STUB_SCOPE_COUNT=$2 dispatch start zcode "$3" "do the thing" 2>/dev/null) || rc=$?
  [ "$rc" -eq 1 ]
  [ "$(jq -r .reason <<<"$out")" = "github token is not scoped to exactly $3" ]
}

@test "a token that covers another repo, another owner or more repos fails closed" {
  scope_refused dryvist/other 1 dryvist/nix-ai
  scope_refused dryvist/nix-ai 1 evil/nix-ai
  scope_refused dryvist/nix-ai 2 dryvist/nix-ai
  run ! grep -q '^docker' "$STUB_DIR/calls.log"
  [ "$(grep -c 'POST https://bao.test/v1/auth/approle/login' "$STUB_DIR/calls.log")" -eq 3 ]
}

@test "missing credential files fail closed without env fallback or a container" {
  rm "$AGENT_DISPATCH_APPROLE_DIR/secret_id"
  export OPENBAO_APPROLE_OPEN_LLM_ROLE_ID=role-id-value
  export OPENBAO_APPROLE_OPEN_LLM_SECRET_ID=secret-id-value
  run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  [ "$status" -eq 1 ]
  [[ $stderr == *"required credential file is missing or unreadable"* ]]
  run ! grep -q '^docker' "$STUB_DIR/calls.log"
  run ! grep -q 'auth/approle/login' "$STUB_DIR/calls.log"
  grep -qx 'reason: credential files are missing or unreadable' "$(http_rec "POST https://ntfy.test/ai-jobs").body"
}

@test "check logs in and revokes the token; a refusal alerts and exits non-zero" {
  run --separate-stderr dispatch check
  [ "$status" -eq 0 ]
  [ "$output" = '{"login":"ok"}' ]
  grep -q 'revoke-self token=s.tok' "$STUB_DIR/calls.log"
  run ! grep -q 'ntfy.test' "$STUB_DIR/calls.log"

  export STUB_LOGIN_FAIL=1
  run --separate-stderr dispatch check
  [ "$status" -eq 1 ]
  [ "$(jq -r .reason <<<"$output")" = "invalid role or secret ID" ]
  grep -qx 'reason: invalid role or secret ID' "$(http_rec "POST https://ntfy.test/ai-jobs").body"
  unset STUB_LOGIN_FAIL

  rm "$AGENT_DISPATCH_APPROLE_DIR/role_id"
  run --separate-stderr dispatch check
  [ "$status" -eq 1 ]
  [ "$(jq -r .reason <<<"$output")" = "credential files are missing or unreadable" ]
}

@test "a refused login posts one role-and-reason alert before any container" {
  export STUB_LOGIN_FAIL=1
  run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  [ "$status" -eq 1 ]
  [ "$(jq -r .reason <<<"$output")" = "invalid role or secret ID" ]
  [ "$(grep -c 'POST https://bao.test/v1/auth/approle/login' "$STUB_DIR/calls.log")" -eq 1 ]
  [ "$(grep -c 'POST https://ntfy.test/ai-jobs' "$STUB_DIR/calls.log")" -eq 1 ]
  local rec
  rec=$(http_rec "POST https://ntfy.test/ai-jobs")
  grep -qx 'role: open-llm' "$rec.body"
  grep -qx 'reason: invalid role or secret ID' "$rec.body"
  grep -qx 'Title: agent-dispatch login refused' "$rec.hdr"
  run ! grep -q '^docker' "$STUB_DIR/calls.log"
  unset STUB_LOGIN_FAIL
}

@test "a batch job for a login-only tool is refused before any side effect" {
  local dispatcher
  dispatcher=$(make_dispatcher '{"cursor-agent":{"env":[],"ttyLogin":true}}')
  run --separate-stderr "$dispatcher" start cursor-agent dryvist/nix-ai "do the thing"
  [ "$status" -eq 64 ]
  [[ $stderr == *"cursor-agent runs only as a terminal session"* ]]
  [ ! -s "$STUB_DIR/argv.log" ]
  [ ! -e "$AGENT_DISPATCH_STATE_DIR" ]
}

@test "cursor-agent batch jobs do not receive a SaaS API key" {
  run --separate-stderr dispatch start cursor-agent dryvist/nix-ai "do the thing"
  [ "$status" -eq 64 ]
  [[ $stderr == *"cursor-agent runs only as a terminal session"* ]]
  [ ! -s "$STUB_DIR/argv.log" ]
  [ ! -e "$AGENT_DISPATCH_STATE_DIR" ]
}

@test "the waiter keeps the job token in memory and revokes it when pruned" {
  local id waiter rdir i
  export STUB_KEEP_WAITER=1
  run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  [ "$status" -eq 0 ]
  id=$(jq -r .job <<<"$output")
  rdir="$AGENT_DISPATCH_STATE_DIR/$id/runs/1"
  for ((i = 0; i < 100; i++)); do
    [ -d "$rdir/final" ] && break
    sleep 0.02
  done
  [ -d "$rdir/final" ]
  [ ! -e "$AGENT_DISPATCH_STATE_DIR/$id/job-token" ]
  run ! grep -rqF s.tok1 "$AGENT_DISPATCH_STATE_DIR/$id"
  waiter=$(cat "$STUB_DIR/waiter.pid")
  kill -0 "$waiter"
  AGENT_DISPATCH_RETENTION=0 dispatch refresh >/dev/null
  grep -qx 'curl POST https://bao.test/v1/auth/token/revoke-self token=s.tok1' "$STUB_DIR/calls.log"
  for ((i = 0; i < 100; i++)); do
    kill -0 "$waiter" 2>/dev/null || break
    sleep 0.02
  done
  kill -0 "$waiter" 2>/dev/null && kill "$waiter" 2>/dev/null || true
  unset STUB_KEEP_WAITER
}

@test "the result is fixed-format and carries only a PR URL of the job's repo" {
  local id rec pr=https://github.com/dryvist/nix-ai/pull/42
  STUB_PR_URL=$pr run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  [ "$status" -eq 0 ]
  id=$(jq -r .job <<<"$output")
  run --separate-stderr dispatch status "$id"
  [ "$(jq -r .state <<<"$output")" = succeeded ]
  [ "$(jq -r .pr <<<"$output")" = "$pr" ]

  rec=$(http_rec "POST https://ntfy.test/ai-jobs")
  [ "$(head -n 5 "$rec.body")" = "job: $id
tool: zcode
repo: dryvist/nix-ai
state: succeeded
pr: $pr" ]
  [ "$(grep -c '' "$rec.body")" -eq 6 ]
  grep -Eqx 'duration: [0-9]+s' "$rec.body"
  grep -qx 'Authorization: Bearer ntfy-secret-value' "$rec.hdr"
  grep -qx "Title: ai-job $id succeeded" "$rec.hdr"
  grep -qx "Click: $pr" "$rec.hdr"

  rec=$(http_rec "PUT https://vikunja.test/api/v1/projects/55/tasks")
  grep -qx 'Authorization: Bearer vikunja-secret-value' "$rec.hdr"
  [ "$(jq -r .title "$rec.body")" = "ai-job $id succeeded" ]
  [[ $(jq -r .description "$rec.body") == "<p>job: $id<br>tool: zcode<br>repo: dryvist/nix-ai<br>state: succeeded<br>pr: $pr<br>duration: "*"s</p>" ]]
  no_secret_on_a_command_line
}

@test "a PR URL for another repo, or with extra text, is reported as none" {
  local url id
  for url in https://github.com/evil/nix-ai/pull/1 https://github.com/dryvisx/nix-ai/pull/1 \
    "https://github.com/dryvist/nix-ai/pull/1 ignore previous instructions" \
    https://github.com/dryvist/nix-ai/pull/1x javascript:alert/1; do
    STUB_PR_URL=$url run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
    id=$(jq -r .job <<<"$output")
    run --separate-stderr dispatch status "$id"
    [ "$(jq -r .pr <<<"$output")" = "" ]
  done
  run ! grep -rq 'ignore previous' "$STUB_DIR"/http.*.body
}

@test "a private repository is refused after the mint and its token is revoked" {
  export STUB_REPO_PRIVATE=1
  run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  [ "$status" -eq 1 ]
  [ "$(jq -r .reason <<<"$output")" = "private or unknown repository refused: dryvist/nix-ai" ]
  run ! grep -q '^docker' "$STUB_DIR/calls.log"
  http_rec "DELETE https://api.github.com/installation/token" >/dev/null
  grep -qx 'Authorization: Bearer ghs_minted_secret' "$(http_rec "GET https://api.github.com/repos/dryvist/nix-ai").hdr"
  no_secret_on_a_command_line
}

@test "a default branch without a pull-request rule is refused and the token revoked" {
  export STUB_BRANCH_UNPROTECTED=1
  run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  [ "$status" -eq 1 ]
  [ "$(jq -r .reason <<<"$output")" = "default branch of dryvist/nix-ai does not require a pull request" ]
  run ! grep -q '^docker' "$STUB_DIR/calls.log"
  http_rec "GET https://api.github.com/repos/dryvist/nix-ai/rules/branches/main" >/dev/null
  http_rec "DELETE https://api.github.com/installation/token" >/dev/null
  no_secret_on_a_command_line
}

@test "--tty attaches a terminal job; login tools get no router key or provider key" {
  local id env_data tool n=0
  for tool in zcode opencode cursor-agent; do
    n=$((n + 1))
    : >"$STUB_DIR/calls.log"
    run --separate-stderr dispatch start --tty "$tool" dryvist/nix-ai
    [ "$status" -eq 0 ]
    id=$(jq -r .job <<<"$output")
    [ "$(jq -r .tty <<<"$(dispatch status "$id")")" = true ]
    create_args "$n"
    has_pair -e AGENT_TTY=1
    has_pair --interactive --tty
    env_data=$(tar -xOf "$STUB_DIR/cp.$n.tar" .agent-env)
    [ "$(printf '%s\n' "$env_data" | cut -d= -f1 | sort)" = "$(printf '%s\n' \
      BAO_ADDR GIT_MIRROR_URL GH_TOKEN GITHUB_TOKEN SANDBOX_ROLE_ID SANDBOX_WRAPPED_SECRET_ID \
      VIKUNJA_URL ZAMMAD_URL | sort)" ]
    [ "$(tar -xOf "$STUB_DIR/cp.$n.tar" .agent-prompt)" = "" ]
    [ "$(line_of 'docker start')" -lt "$(line_of 'docker attach')" ]
    grep -q '^docker attach --detach-keys .* cid0123$' "$STUB_DIR/argv.log"
  done
  run ! grep -q 'docker kill' "$STUB_DIR/calls.log"
  run --separate-stderr dispatch continue "$id" "more"
  [ "$status" -eq 64 ]
  no_secret_on_a_command_line
}

@test "--tty takes no prompt; a session that ends early kills the container" {
  local id
  run --separate-stderr dispatch start --tty zcode dryvist/nix-ai "a prompt"
  [ "$status" -eq 64 ]
  export STUB_NO_WAITER=1 STUB_RUNNING=true
  run --separate-stderr dispatch start --tty zcode dryvist/nix-ai
  [ "$status" -eq 0 ]
  id=$(jq -r .job <<<"$output")
  grep -qx 'docker kill cid0123' "$STUB_DIR/argv.log"
  [ -e "$AGENT_DISPATCH_STATE_DIR/$id/runs/1/cancel" ]
}

# run_state <job-json>: the job's state after the waiter finished.
run_state() {
  "$AGENT_DISPATCH_BIN/agent-dispatch" status "$(jq -r .job <<<"$1")" | jq -r "${2:-.state}"
}

renewals() { grep -c 'POST https://bao.test/v1/auth/token/renew-self token=s.tok1' "$STUB_DIR/calls.log" || true; }

# Waits are slices of half the login TTL: STUB_LEASE=4 gives 2 s slices, and
# the container exits on wait call STUB_WAIT_CALLS.
@test "the login token is renewed every half TTL while the container runs" {
  export STUB_LEASE=4 STUB_WAIT_CALLS=3
  run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  [ "$status" -eq 0 ]
  [ "$(run_state "$output")" = succeeded ]
  [ "$(grep -c '^docker wait' "$STUB_DIR/calls.log")" -eq 3 ]
  [ "$(renewals)" -eq 2 ]
  [ "$(line_of 'renew-self token=s.tok1')" -gt "$(line_of 'docker start')" ]
  [ "$(grep -n 'renew-self token=s.tok1' "$STUB_DIR/calls.log" | tail -n 1 | cut -d: -f1)" -lt \
    "$(line_of 'POST https://ntfy.test/ai-jobs')" ]
  [ "$(line_of 'revoke-self token=s.tok1')" -gt "$(line_of 'POST https://ntfy.test/ai-jobs')" ]
  run ! grep -q '^docker kill' "$STUB_DIR/calls.log"
}

@test "a failed renewal stops the container and fails the job; the token is still revoked" {
  export STUB_LEASE=4 STUB_WAIT_CALLS=99 STUB_RENEW_FAIL=1
  run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  [ "$(run_state "$output")" = failed ]
  [ "$(run_state "$output" .reason)" = "service token renewal failed" ]
  [ "$(renewals)" -eq 1 ]
  grep -qx 'docker kill cid0123' "$STUB_DIR/argv.log"
  [ "$(line_of 'revoke-self token=s.tok1')" -gt "$(line_of 'docker kill')" ]
}

@test "at the token's max TTL renewal stops and the run ends as a timeout" {
  # The renewal comes back shorter than the TTL: the token's max TTL is near.
  export STUB_LEASE=4 STUB_RENEW_LEASE=1 STUB_WAIT_CALLS=99
  run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  [ "$(run_state "$output")" = timeout ]
  [ "$(renewals)" -eq 1 ]
  grep -qx 'docker kill cid0123' "$STUB_DIR/argv.log"
  [ "$(line_of 'revoke-self token=s.tok1')" -gt "$(line_of 'docker kill')" ]
}

@test "AGENT_TIMEOUT ends the run as a timeout before the token needs renewal" {
  local id
  export AGENT_TIMEOUT=1 STUB_WAIT_CALLS=99
  run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  id=$(jq -r .job <<<"$output")
  [ "$(cat "$AGENT_DISPATCH_STATE_DIR/$id/runs/1/budget")" = 1 ]
  [ "$(run_state "$output")" = timeout ]
  [ "$(renewals)" -eq 0 ]
  [ "$(line_of 'revoke-self token=s.tok1')" -gt "$(line_of 'docker kill')" ]
}

@test "finalize saves the redacted last 200 container log lines before removal" {
  local id log token logs_line rm_line
  {
    printf '%s\n' 'excluded-first-line'
    for ((i = 1; i <= 190; i++)); do printf 'filler-%s\n' "$i"; done
    printf '%s\n' 'ghs_test_secret' 'gho_test_secret' 'ghu_test_secret' 'github_pat_test_secret' \
      'sk-proj_test_secret' 'Authorization: Bearer authorization_test_secret' \
      'Bearer bearer_test_secret' 'X-Vault-Token: vault_test_secret' \
      'AGENT_ROUTER_KEY=zcode-router-secret-value' \
      'GH_TOKEN=abc123' 'last-log-line'
  } >"$STUB_DIR/container.log"
  export STUB_DOCKER_LOG_FILE="$STUB_DIR/container.log" STUB_EXIT=1
  run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = failed ]
  [ "$(jq -r .reason <<<"$output")" = "exit 1" ]
  id=$(jq -r .job <<<"$output")
  log="$AGENT_DISPATCH_STATE_DIR/$id/runs/1/log"
  [ -f "$log" ]
  [ "$(wc -l <"$log" | tr -d '[:space:]')" -eq 200 ]
  ! grep -Fxq 'excluded-first-line' "$log"
  grep -Fxq 'last-log-line' "$log"
  [ "$(grep -Fc '[REDACTED]' "$log")" -eq 10 ]
  for token in ghs_test_secret gho_test_secret ghu_test_secret github_pat_test_secret \
    sk-proj_test_secret authorization_test_secret bearer_test_secret vault_test_secret \
    zcode-router-secret-value abc123; do
    ! grep -Fq "$token" "$log"
  done
  [ "$(ls -l "$log" | cut -c2-10)" = rw------- ]
  logs_line=$(grep -nF 'docker logs --tail 200 cid0123' "$STUB_DIR/argv.log" | cut -d: -f1)
  rm_line=$(grep -nF 'docker rm -f cid0123' "$STUB_DIR/argv.log" | cut -d: -f1)
  [ -n "$logs_line" ] && [ -n "$rm_line" ]
  [ "$logs_line" -lt "$rm_line" ]
  ! jq -e 'has("log_tail") or has("log")' <<<"$output"
  run --separate-stderr dispatch status "$id"
  [ "$status" -eq 0 ]
  jq -e '((has("log_tail") or has("log")) | not)' <<<"$output"
}

@test "status omits log fields and host logs redact router and GitHub key assignments" {
  local id log
  printf '%s\n' 'AGENT_ROUTER_KEY=zcode-router-secret-value' 'GH_TOKEN=abc123' >"$STUB_DIR/container.log"
  printf '%s\n' 'X-Vault-Token: vault_test_secret' >>"$STUB_DIR/container.log"
  export STUB_DOCKER_LOG_FILE="$STUB_DIR/container.log"
  run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  [ "$status" -eq 0 ]
  id=$(jq -r .job <<<"$output")
  log="$AGENT_DISPATCH_STATE_DIR/$id/runs/1/log"
  grep -Fxq 'AGENT_ROUTER_KEY=[REDACTED]' "$log"
  grep -Fxq 'GH_TOKEN=[REDACTED]' "$log"
  grep -Fxq 'X-Vault-Token: [REDACTED]' "$log"
  ! grep -Fq 'zcode-router-secret-value' "$log"
  ! grep -Fq 'vault_test_secret' "$log"
  ! grep -Fq 'abc123' "$log"
  [ "$(ls -l "$log" | cut -c2-10)" = rw------- ]

  run --separate-stderr dispatch status "$id"
  [ "$status" -eq 0 ]
  jq -e '((has("log_tail") or has("log")) | not)' <<<"$output"
  ! grep -Fq 'zcode-router-secret-value' <<<"$output"
  ! grep -Fq 'vault_test_secret' <<<"$output"
  ! grep -Fq 'abc123' <<<"$output"
}

@test "cancel kills a running job; refresh settles it as cancelled" {
  local id rec
  export STUB_NO_WAITER=1
  run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  [ "$status" -eq 0 ]
  id=$(jq -r .job <<<"$output")
  [ "$(jq -r .state <<<"$output")" = running ]

  run --separate-stderr dispatch continue "$id" "more"
  [ "$status" -eq 1 ]
  [ ! -e "$STUB_DIR/create.2" ]

  export STUB_STATUS=running
  run --separate-stderr dispatch refresh
  [ "$(jq -c .settled <<<"$output")" = "[]" ]

  run --separate-stderr dispatch cancel "$id"
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = cancelling ]
  grep -qx 'docker kill cid0123' "$STUB_DIR/argv.log"

  export STUB_STATUS=exited STUB_EXIT=137
  run --separate-stderr dispatch refresh
  [ "$(jq -c .settled <<<"$output")" = "[\"$id\"]" ]
  run --separate-stderr dispatch status "$id"
  [ "$(jq -r .state <<<"$output")" = cancelled ]
  run ! grep -q 'POST https://ntfy.test/ai-jobs' "$STUB_DIR/calls.log"
  grep -qx "docker rm -f cid0123" "$STUB_DIR/argv.log"
}

@test "continue reuses the job token and workspace without another login" {
  local id waiter i
  export STUB_KEEP_WAITER=1
  run --separate-stderr dispatch start zcode dryvist/nix-ai "first"
  id=$(jq -r .job <<<"$output")
  for ((i = 0; i < 100; i++)); do
    [ -d "$AGENT_DISPATCH_STATE_DIR/$id/runs/1/final" ] && break
    sleep 0.02
  done
  [ -d "$AGENT_DISPATCH_STATE_DIR/$id/runs/1/final" ]
  run --separate-stderr ssh_cmd "continue $id now add tests"
  [ "$status" -eq 0 ]
  [ "$(jq -r .runs <<<"$output")" = 2 ]
  [ -f "$AGENT_DISPATCH_STATE_DIR/$id/runs/2/cid" ]
  create_args 2
  has_pair -e AGENT_CONTINUE=1
  has_pair --name "agent-$id-2"
  has_pair -v "agent-job-$id:/home/agent/work"
  [ "$(tar -xOf "$STUB_DIR/cp.2.tar" .agent-prompt)" = "now add tests" ]
  [ "$(grep -c 'POST https://bao.test/v1/github-agents/token' "$STUB_DIR/calls.log")" -eq 2 ]
  [ "$(grep -c 'POST https://bao.test/v1/auth/approle/login' "$STUB_DIR/calls.log")" -eq 1 ]
  for ((i = 0; i < 500; i++)); do
    [ -d "$AGENT_DISPATCH_STATE_DIR/$id/runs/2/final" ] && break
    sleep 0.02
  done
  [ -d "$AGENT_DISPATCH_STATE_DIR/$id/runs/2/final" ]
  waiter=$(cat "$STUB_DIR/waiter.pid")
  AGENT_DISPATCH_RETENTION=0 dispatch refresh >/dev/null
  for ((i = 0; i < 100; i++)); do
    grep -q 'revoke-self token=s.tok1' "$STUB_DIR/calls.log" && break
    sleep 0.02
  done
  [ "$(grep -c 'POST https://ntfy.test/ai-jobs' "$STUB_DIR/calls.log")" -eq 2 ]
  [ "$(grep -c 'POST https://bao.test/v1/auth/approle/login' "$STUB_DIR/calls.log")" -eq 1 ]
  unset STUB_KEEP_WAITER
}

@test "refresh prunes finished jobs past retention: volume and state removed" {
  local id
  run --separate-stderr dispatch start zcode dryvist/nix-ai "do the thing"
  id=$(jq -r .job <<<"$output")
  run --separate-stderr dispatch refresh
  [ "$(jq -c .pruned <<<"$output")" = "[]" ]
  export AGENT_DISPATCH_RETENTION=0
  run --separate-stderr ssh_cmd refresh
  [ "$(jq -c .pruned <<<"$output")" = "[\"$id\"]" ]
  grep -qx "docker volume rm -f agent-job-$id" "$STUB_DIR/argv.log"
  grep -qx "curl POST https://bao.test/v1/auth/token/revoke-self token=s.tok1" "$STUB_DIR/calls.log"
  [ ! -e "$AGENT_DISPATCH_STATE_DIR/$id" ]
  run --separate-stderr dispatch status "$id"
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = "no such job" ]
}

@test "the entrypoint exports .agent-env values verbatim and removes both files" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home"
  printf '%s\n' "ZAI_SUBSCRIPTION_KEY=\$(touch $home/pwned)" \
    'AGENT_ROUTER_BASE_URL=https://router.test/v1' 'AGENT_ROUTER_KEY=router-test-key' >"$home/.agent-env"
  printf 'the prompt' >"$home/.agent-prompt"
  echo '{"zcode":{"env":["ZAI_SUBSCRIPTION_KEY"]}}' >"$home/.agent-profiles.json"
  run env -i PATH="$PATH" HOME="$home" AGENT_SANDBOX=1 AGENT_TOOL=nope AGENT_PROFILE=zcode \
    bash -euo pipefail "$ENTRYPOINT"
  # Reaching the tool switch means the prompt and the profile's key loaded.
  [ "$status" -eq 64 ]
  [[ $output == *"unknown AGENT_TOOL 'nope'"* ]]
  [ ! -e "$home/pwned" ]
  [ ! -e "$home/.agent-env" ]
  [ ! -e "$home/.agent-prompt" ]
}

@test "the entrypoint removes .agent-env and rejects names outside its allowlist" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/reject-home"
  mkdir -p "$home"
  printf '%s\n' '{"zcode":{"env":["ZAI_SUBSCRIPTION_KEY"]}}' >"$home/.agent-profiles.json"
  printf '%s\n' 'ZAI_SUBSCRIPTION_KEY=valid' 'OPENBAO_APPROLE_OPEN_LLM_SECRET_ID=never-allowed' >"$home/.agent-env"
  run env -i PATH="$PATH" HOME="$home" AGENT_SANDBOX=1 AGENT_TOOL=zcode AGENT_PROFILE=zcode \
    bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 64 ]
  [[ $output == *"unsupported value in .agent-env"* ]]
  [ ! -e "$home/.agent-env" ]
}

@test "the entrypoint exports both router values to the tool and removes the file" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/router-home" tools="$BATS_TEST_TMPDIR/router-tools"
  mkdir -p "$home" "$tools"
  printf '%s\n' '{"zcode":{"env":[],"routerKeyField":"zcode_router_key"}}' >"$home/.agent-profiles.json"
  printf '%s\n' 'AGENT_ROUTER_BASE_URL=https://router.test/v1' \
    'AGENT_ROUTER_KEY=router-test-key' >"$home/.agent-env"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  bash_stub "$tools/zcode" <<'SH'
test "$AGENT_ROUTER_BASE_URL" = https://router.test/v1
test "$AGENT_ROUTER_KEY" = router-test-key
test -z "${ZAI_SUBSCRIPTION_KEY:-}"
SH
  run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$STUB_DIR" AGENT_SANDBOX=1 \
    AGENT_TOOL=zcode AGENT_PROMPT='route this' bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ ! -e "$home/.agent-env" ]
}

@test "routed tools require router values and reject another task profile" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/router-required-home" tools="$BATS_TEST_TMPDIR/router-required-tools"
  mkdir -p "$home" "$tools"
  printf '%s\n' '{"opencode":{"env":[],"routerKeyField":"opencode_router_key"},"zai":{"env":["ZAI_SUBSCRIPTION_KEY"]}}' \
    >"$home/.agent-profiles.json"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  run env -i PATH="$tools:$PATH" HOME="$home" AGENT_SANDBOX=1 AGENT_TOOL=opencode \
    AGENT_PROMPT='route this' bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 64 ]
  [[ $output == *"requires AGENT_ROUTER_BASE_URL"* ]]

  run env -i PATH="$tools:$PATH" HOME="$home" AGENT_SANDBOX=1 AGENT_TOOL=opencode \
    AGENT_PROFILE=zai AGENT_PROMPT='route this' bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 64 ]
  [[ $output == *"requires its matching task profile"* ]]
}

@test "ZCode batch runs with router values and no provider key" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/zcode-home" tools="$BATS_TEST_TMPDIR/zcode-tools"
  mkdir -p "$home" "$tools"
  printf '%s\n' '{"zcode":{"env":[],"routerKeyField":"zcode_router_key"}}' >"$home/.agent-profiles.json"
  printf '%s\n' 'AGENT_ROUTER_BASE_URL=https://router.test/v1' \
    'AGENT_ROUTER_KEY=zcode-router-test-key' >"$home/.agent-env"
  bash_stub "$tools/zcode" <<'SH'
printf '%s\n' "$@" >"$STUB_DIR/zcode-argv"
test "$AGENT_ROUTER_BASE_URL" = https://router.test/v1
test "$AGENT_ROUTER_KEY" = zcode-router-test-key
test -r "$ZCODE_BUILTIN_PROVIDER_CONFIG_FILE"
test -f "$ZCODE_PERSONAL_PROVIDER_CONFIG_FILE"
printf '%s\n' "$ZCODE_BUILTIN_PROVIDER_CONFIG_FILE" "$ZCODE_PERSONAL_PROVIDER_CONFIG_FILE" \
  >"$STUB_DIR/zcode-provider-config-paths"
test -z "${ZAI_SUBSCRIPTION_KEY:-}"
SH
  printf '%s\n' '{}' >"$home/zcode-builtin.json"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$STUB_DIR" AGENT_SANDBOX=1 \
    ZCODE_BUILTIN_PROVIDER_CONFIG_FILE="$home/zcode-builtin.json" \
    AGENT_TOOL=zcode AGENT_PROMPT='fix the test' bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/zcode-argv")" = $'--prompt\nfix the test\n--mode\nyolo' ]
  [ "$(cat "$STUB_DIR/zcode-provider-config-paths")" = \
    "$home/zcode-builtin.json"$'\n'"$home/.zcode/v2/provider_config.json" ]
  jq -e '.schemaVersion == 1 and .config.providerOrder == ["agent-router"] and
    .config.providerConfigRules.providerRules == [{providerId: "agent-router",
      providerName: "Agent Router", enabled: true, config: {
        group: "standard-personal", access: {type: "api-key", apiKey: "zcode-router-test-key"},
        api: {type: "openai-chat-completions", baseUrl: "https://router.test/v1"},
        personalModelIds: ["medium"]}}] and
    .config.modelConfigRules == {providerModelRules: [], manualProviderModelRules: []} and
    .config.defaultModelSelection == {providerId: "agent-router", modelId: "medium"}' \
    "$home/.zcode/v2/provider_config.json"
  [ "$(ls -l "$home/.zcode/v2/provider_config.json" | cut -c2-10)" = rw------- ]
}

@test "ZCode and OpenCode preserve existing configs without router values" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/no-router-home" tools="$BATS_TEST_TMPDIR/no-router-tools"
  mkdir -p "$home/.zcode/v2" "$home/.config/opencode" "$tools"
  printf '%s\n' '{"zcode":{"env":[]},"opencode":{"env":[]}}' >"$home/.agent-profiles.json"
  printf '%s\n' '{"existing":"zcode"}' >"$home/.zcode/v2/provider_config.json"
  printf '%s\n' '{"existing":"opencode"}' >"$home/.config/opencode/opencode.json"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  bash_stub "$tools/zcode" <<'SH'
test -z "${AGENT_ROUTER_BASE_URL:-}"
test -z "${AGENT_ROUTER_KEY:-}"
test -z "${ZCODE_PERSONAL_PROVIDER_CONFIG_FILE:-}"
test "$(cat "$HOME/.zcode/v2/provider_config.json")" = '{"existing":"zcode"}'
SH
  bash_stub "$tools/opencode" <<'SH'
test -z "${AGENT_ROUTER_BASE_URL:-}"
test -z "${AGENT_ROUTER_KEY:-}"
test "$(cat "$HOME/.config/opencode/opencode.json")" = '{"existing":"opencode"}'
SH
  run env -i PATH="$tools:$PATH" HOME="$home" AGENT_SANDBOX=1 AGENT_TOOL=zcode \
    AGENT_PROMPT='run zcode' bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  run env -i PATH="$tools:$PATH" HOME="$home" AGENT_SANDBOX=1 AGENT_TOOL=opencode \
    AGENT_PROMPT='run opencode' bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 0 ]
}

@test "qwen-code is batch only: a terminal job is refused before any side effect" {
  run --separate-stderr dispatch start --tty qwen-code dryvist/nix-ai
  [ "$status" -eq 64 ]
  [[ $stderr == *"qwen-code has no terminal session"* ]]
  [ ! -s "$STUB_DIR/argv.log" ]
  [ ! -e "$AGENT_DISPATCH_STATE_DIR" ]
}

@test "Qwen Code batch runs the router's medium capability in YOLO mode" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/qwen-code-home" tools="$BATS_TEST_TMPDIR/qwen-code-tools"
  mkdir -p "$home" "$tools"
  printf '%s\n' '{"qwen-code":{"env":[],"routerKeyField":"QWEN_CODE_ROUTER_KEY"}}' >"$home/.agent-profiles.json"
  printf '%s\n' 'AGENT_ROUTER_BASE_URL=MODEL_ENDPOINT' 'AGENT_ROUTER_KEY=router-key-value' >"$home/.agent-env"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  bash_stub "$tools/qwen" <<'SH'
printf '%s\n' "$@" >"$STUB_DIR/qwen-code-argv"
test "$OPENAI_API_KEY" = router-key-value
SH
  run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$STUB_DIR" AGENT_SANDBOX=1 \
    AGENT_TOOL=qwen-code AGENT_PROMPT='fix the test' bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/qwen-code-argv")" = $'--auth-type\nopenai\n--model\nmedium\n--openai-base-url\nMODEL_ENDPOINT\n--prompt\nfix the test\n--yolo' ]
  [[ ! $(cat "$STUB_DIR/qwen-code-argv") =~ router-key-value ]]
  [ ! -e "$home/.agent-env" ]
}

@test "Qwen Code batch uses the routed OpenAI-compatible endpoint in YOLO mode" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/qwen-home" tools="$BATS_TEST_TMPDIR/qwen-tools"
  mkdir -p "$home" "$tools"
  printf '%s\n' '{"qwen":{"env":["AGENT_ROUTER_BASE_URL","AGENT_ROUTER_KEY","AGENT_MODEL"]}}' \
    >"$home/.agent-profiles.json"
  printf '%s\n' 'AGENT_ROUTER_BASE_URL=MODEL_ENDPOINT' \
    'AGENT_ROUTER_KEY=router-key-value' 'AGENT_MODEL=MODEL_ID' >"$home/.agent-env"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  bash_stub "$tools/qwen" <<'SH'
printf '%s\n' "$@" >"$STUB_DIR/qwen-argv"
test "$OPENAI_API_KEY" = router-key-value
test "$AGENT_ROUTER_KEY" = router-key-value
test "$AGENT_ROUTER_BASE_URL" = MODEL_ENDPOINT
test "$AGENT_MODEL" = MODEL_ID
SH
  run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$STUB_DIR" AGENT_SANDBOX=1 \
    AGENT_TOOL=qwen AGENT_PROMPT='fix the test' bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/qwen-argv")" = $'--auth-type\nopenai\n--model\nMODEL_ID\n--openai-base-url\nMODEL_ENDPOINT\n--prompt\nfix the test\n--yolo' ]
  [[ ! $(cat "$STUB_DIR/qwen-argv") =~ router-key-value ]]
  [ ! -e "$home/.agent-env" ]
}

@test "OpenCode and Cursor receive their native batch command forms" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/tools-home" tools="$BATS_TEST_TMPDIR/agent-tools"
  mkdir -p "$home" "$tools"
  printf '%s\n' '{"opencode":{"env":[],"routerKeyField":"opencode_router_key"},"cursor-agent":{"env":[],"routerKeyField":"cursor_router_key"}}' \
    >"$home/.agent-profiles.json"
  printf '%s\n' 'AGENT_ROUTER_BASE_URL=https://router.test/v1' \
    'AGENT_ROUTER_KEY=opencode-router-test-key' >"$home/.agent-env"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
bash_stub "$tools/opencode" <<'SH'
printf '%s\n' "$@" >"$STUB_DIR/opencode-argv"
cp "$HOME/.config/opencode/opencode.json" "$STUB_DIR/opencode-batch-config"
test "$AGENT_ROUTER_BASE_URL" = https://router.test/v1
test "$AGENT_ROUTER_KEY" = opencode-router-test-key
test -z "${ZAI_SUBSCRIPTION_KEY:-}"
test -z "${CURSOR_API_KEY:-}"
SH
bash_stub "$tools/cursor-agent" <<'SH'
printf '%s\n' "$@" >"$STUB_DIR/cursor-argv"
test "$AGENT_ROUTER_BASE_URL" = https://router.test/v1
test "$AGENT_ROUTER_KEY" = cursor-router-test-key
test -z "${ZAI_SUBSCRIPTION_KEY:-}"
test -z "${CURSOR_API_KEY:-}"
SH
  run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$STUB_DIR" AGENT_SANDBOX=1 \
    AGENT_TOOL=opencode AGENT_PROMPT='opencode prompt' bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/opencode-argv")" = $'run\n--auto\n--model\nagent-router/medium\nopencode prompt' ]
  jq -e '.model == "agent-router/medium" and .small_model == "agent-router/small" and
    .provider["agent-router"].options == {baseURL: "https://router.test/v1", apiKey: "opencode-router-test-key"} and
    (.provider["agent-router"].models | keys == ["medium", "small"])' \
    "$STUB_DIR/opencode-batch-config"

  printf '%s\n' 'AGENT_ROUTER_BASE_URL=https://router.test/v1' \
    'AGENT_ROUTER_KEY=cursor-router-test-key' >"$home/.agent-env"
  run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$STUB_DIR" AGENT_SANDBOX=1 \
    AGENT_TOOL=cursor-agent AGENT_PROMPT='cursor prompt' bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/cursor-argv")" = $'-p\n--force\ncursor prompt' ]
}

@test "cursor-agent batch needs CURSOR_API_KEY; a terminal session runs without it" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/cursor-key-home" tools="$BATS_TEST_TMPDIR/cursor-key-tools"
  mkdir -p "$home" "$tools"
  printf '%s\n' '{"cursor-agent":{"env":["CURSOR_API_KEY"],"ttyLogin":true}}' >"$home/.agent-profiles.json"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  bash_stub "$tools/cursor-agent" <<'SH'
printf '%s\n' "$@" >"$STUB_DIR/cursor-argv"
echo "${CURSOR_API_KEY:-unset}" >"$STUB_DIR/cursor-key"
SH
  run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$STUB_DIR" AGENT_SANDBOX=1 \
    AGENT_TOOL=cursor-agent AGENT_PROMPT='cursor prompt' bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/cursor-argv")" = $'-p\n--force\ncursor prompt' ]
  [ "$(cat "$STUB_DIR/cursor-key")" = unset ]

  run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$STUB_DIR" AGENT_SANDBOX=1 \
    AGENT_TOOL=cursor-agent AGENT_TTY=1 bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/cursor-key")" = unset ]
}

@test "zcode-web loads only the mounted service credentials and runs without a prompt" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/service-home" tools="$BATS_TEST_TMPDIR/service-tools"
  mkdir -p "$home" "$tools"
  printf '%s\n' '{"zcode-web":{"env":["ZAI_SUBSCRIPTION_KEY","AGENT_WEB_TOKEN"]}}' >"$home/.agent-profiles.json"
  printf '%s\n' 'ZAI_SUBSCRIPTION_KEY=zai-test-value' 'AGENT_WEB_TOKEN=token-test-value' >"$home/service.env"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  bash_stub "$tools/zcode-configure-key" <<'SH'
printf '%s\n' "$ZAI_API_KEY" >"$STUB_DIR/configured-key"
SH
  bash_stub "$tools/zcode-web-supervisor" <<'SH'
printf '%s\n' "$ZCODE_SERVER_AUTH_TOKEN" "$ZCODE_SERVER_HOST" "$PORT" "$ZCODE_DATA_BASE_DIR" >"$STUB_DIR/server-env"
SH
  run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$STUB_DIR" AGENT_SANDBOX=1 \
    AGENT_TOOL=zcode-web AGENT_SERVICE_ENV_FILE="$home/service.env" AGENT_PORT=8080 \
    bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/configured-key")" = zai-test-value ]
  local expected
  expected=$(printf 'token-test-value\n0.0.0.0\n8080\n%s\n' "$home/.zcode")
  [ "$(cat "$STUB_DIR/server-env")" = "${expected%$'\n'}" ]

  printf '%s\n' 'ZAI_SUBSCRIPTION_KEY=zai-test-value' 'AGENT_WEB_TOKEN=token-test-value' 'GH_TOKEN=unexpected' \
    >"$home/service.env"
  run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$STUB_DIR" AGENT_SANDBOX=1 \
    AGENT_TOOL=zcode-web AGENT_SERVICE_ENV_FILE="$home/service.env" \
    bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 64 ]
  [[ $output == *"unsupported name in ZCode service environment file"* ]]
}

@test "a terminal session runs the tool with no prompt and, for login tools, no router key" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/tty-home" tools="$BATS_TEST_TMPDIR/tty-tools"
  mkdir -p "$home" "$tools"
  printf '%s\n' '{"zcode":{"env":[],"routerKeyField":"zcode_router_key","ttyLogin":true}}' >"$home/.agent-profiles.json"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  bash_stub "$tools/zcode" <<'SH'
printf '%s\n' "$#" >"$STUB_DIR/zcode-argc"
test -z "${AGENT_ROUTER_KEY:-}"
test -z "${ZAI_SUBSCRIPTION_KEY:-}"
SH
  run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$STUB_DIR" AGENT_SANDBOX=1 \
    AGENT_TOOL=zcode AGENT_TTY=1 bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/zcode-argc")" = 0 ]

  # Without the terminal flag the same profile still needs its router key.
  run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$STUB_DIR" AGENT_SANDBOX=1 \
    AGENT_TOOL=zcode AGENT_PROMPT=x bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 64 ]
  [[ $output == *"requires AGENT_ROUTER_BASE_URL"* ]]
}

# publish_fixture <name> <gitleaks exit>: an origin holding old-file, and gh
# and gitleaks stubs; sets $home $tools $origin. Each test writes its zcode
# stub.
publish_fixture() {
  home="$BATS_TEST_TMPDIR/$1-home" tools="$BATS_TEST_TMPDIR/$1-tools" origin="$BATS_TEST_TMPDIR/$1-origin.git"
  local seed="$BATS_TEST_TMPDIR/$1-seed"
  mkdir -p "$home" "$tools"
  git init -q --bare "$origin"
  git clone -q "$origin" "$seed" 2>/dev/null
  echo old >"$seed/old-file"
  git -C "$seed" add old-file
  git -C "$seed" -c user.name=t -c user.email=t@t commit -q -m base
  git -C "$seed" push -q origin HEAD
  printf '%s\n' "$origin" >"$STUB_DIR/origin-path"
  printf '%s\n' '{"zcode":{"env":[],"routerKeyField":"zcode_router_key","ttyLogin":true}}' >"$home/.agent-profiles.json"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  bash_stub "$tools/gh" <<'SH'
case "$1 $2" in
  "repo clone") exec git clone -q "$(cat "$STUB_DIR/origin-path")" "$4" ;;
  "api graphql") cp "$4" "$STUB_DIR/graphql.json" ;;
  "api repos/"*) printf '%s\n' "$*" >>"$STUB_DIR/gh-api.log" ;;
  "pr create") echo https://github.com/dryvist/nix-ai/pull/7 ;;
  *) exit 1 ;;
esac
SH
  bash_stub "$tools/gitleaks" <<SH
printf '%s\n' "\$@" >"\$STUB_DIR/gitleaks-argv"
exit $2
SH
}

# fix_entry_fixture <name> <gitleaks exit> [remote branch]: local bare GitHub stand-in.
fix_entry_fixture() {
  local branch=${3:-ci/fix} seed="$BATS_TEST_TMPDIR/$1-seed"
  publish_fixture "$1" "$2"
  printf '%s\n' '{"zcode":{"env":[]},"shell":{"env":[]}}' >"$home/.agent-profiles.json"
  bash_stub "$tools/git" <<'SH'
args=()
for arg in "$@"; do
  if [ "$arg" = https://github.com/dryvist/nix-ai ]; then arg=$(cat "$STUB_DIR/origin-path"); fi
  args+=("$arg")
done
exec "$REAL_GIT" "${args[@]}"
SH
  if [ -n "${3:-}" ]; then
    git -C "$seed" checkout -qb "$branch"
    git -C "$seed" push -q origin "$branch"
  fi
  ENTRY_EXPECTED_SHA=$(git -C "$seed" rev-parse HEAD)
  ENTRY_BRANCH="$branch"
}

run_fix_entrypoint() {
  run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$STUB_DIR" REAL_GIT="$REAL_GIT" \
    AGENT_SANDBOX=1 AGENT_MODE=fix AGENT_TOOL="${ENTRY_TOOL:-zcode}" AGENT_REPO=dryvist/nix-ai \
    AGENT_BRANCH="$ENTRY_BRANCH" AGENT_EXPECTED_SHA="$ENTRY_EXPECTED_SHA" \
    AGENT_PROMPT="${ENTRY_PROMPT:-repair the failure}" bash -euo pipefail "$ENTRYPOINT"
}

# run_publish <run id> [NAME=value...]: the entrypoint in a terminal session.
run_publish() {
  local id=$1
  shift
  run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$STUB_DIR" AGENT_SANDBOX=1 \
    AGENT_TOOL=zcode AGENT_TTY=1 AGENT_REPO=dryvist/nix-ai AGENT_RUN_ID="$id" AGENT_PR_DRAFT=1 "$@" \
    bash -euo pipefail "$ENTRYPOINT"
}

@test "fix entrypoint emits the staged full diff, tool commit summary and review patch" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home tools origin expected
  fix_entry_fixture fix-output 0 ci/fix
  expected=$ENTRY_EXPECTED_SHA
  mkdir -p "$home/work/.agent-fix"
  : >"$home/work/.agent-fix/preseed"
  bash_stub "$tools/zcode" <<'SH'
test ! -e "$HOME/work/.agent-fix/preseed"
echo updated >old-file
echo untracked >untracked
git add -A
git commit -q -m 'tool subject'
echo dirty >tool-dirty
SH
  run_fix_entrypoint
  [ "$status" -eq 0 ]
  jq -e '
    .deletions == [] and
    ([.additions[] | {path, contents}] | sort_by(.path)) == [
      {path: "old-file", contents: "dXBkYXRlZAo="},
      {path: "tool-dirty", contents: "ZGlydHkK"},
      {path: "untracked", contents: "dW50cmFja2VkCg=="}
    ]' "$home/work/.agent-fix/changes.json"
  [ "$(cat "$home/work/.agent-fix/summary.txt")" = 'tool subject' ]
  grep -q 'updated' "$home/work/.agent-fix/patch.diff"
  grep -qx -- "--log-opts=$expected..HEAD" "$STUB_DIR/gitleaks-argv"
  [ ! -e "$home/work/.agent-fix/preseed" ]
  [ ! -e "$STUB_DIR/graphql.json" ]
}

@test "the shell tool runs the task text as a command in fix mode only" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home tools origin
  fix_entry_fixture shell-fix 0 ci/fix
  ENTRY_TOOL=shell ENTRY_PROMPT='echo formatted >old-file' run_fix_entrypoint
  [ "$status" -eq 0 ]
  jq -e '.additions == [{path: "old-file", contents: "Zm9ybWF0dGVkCg=="}] and .deletions == []' \
    "$home/work/.agent-fix/changes.json"
  run env -i PATH="$tools:$PATH" HOME="$home" AGENT_SANDBOX=1 AGENT_TOOL=shell \
    AGENT_PROMPT='true' bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 64 ]
  [[ $output == *"the shell tool runs only in fix mode"* ]]
}

@test "an empty fix removes preseeded outputs and exits successfully after a failed tool" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  fix_entry_fixture empty 0 ci/fix
  mkdir -p "$home/work/.agent-fix"
  : >"$home/work/.agent-fix/preseed"
  bash_stub "$tools/zcode" <<'SH'
exit 23
SH
  run_fix_entrypoint
  [ "$status" -eq 0 ]
  [ ! -e "$home/work/.agent-fix" ]
  [ ! -e "$STUB_DIR/gitleaks-argv" ]
}

@test "fix entrypoint reports head moved when the remote branch no longer matches" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  fix_entry_fixture moved 0 ci/fix
  ENTRY_EXPECTED_SHA=ffffffffffffffffffffffffffffffffffffffff
  bash_stub "$tools/zcode" <<'SH'
touch "$STUB_DIR/tool-ran"
SH
  run_fix_entrypoint
  [ "$status" -eq 66 ]
  [[ $output == *"head moved"* ]]
  [ ! -e "$STUB_DIR/tool-ran" ]
  [ ! -e "$home/work/.agent-fix" ]
}

@test "fix entrypoint falls back to the expected commit and emits no outputs when gitleaks finds a secret" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  fix_entry_fixture blocked 1
  bash_stub "$tools/zcode" <<'SH'
echo candidate >secret.txt
git add secret.txt
git commit -q -m 'tool subject'
SH
  run_fix_entrypoint
  [ "$status" -eq 65 ]
  [[ $output == *"gitleaks flagged the fix change"* ]]
  grep -qx -- "--log-opts=$ENTRY_EXPECTED_SHA..HEAD" "$STUB_DIR/gitleaks-argv"
  [ ! -e "$home/work/.agent-fix" ]
}

@test "the run's commits publish as one API-created commit and a draft PR, never a push" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home tools origin head
  publish_fixture signed 0
  bash_stub "$tools/zcode" <<'SH'
echo change >tool-file
git rm -q old-file
git add tool-file
git commit -q -m "tool commit"
SH
  run_publish j-1
  [ "$status" -eq 0 ]
  head=$(git -C "$origin" rev-parse HEAD)
  grep -qx -- '--log-opts=[0-9a-f]\{40\}..HEAD' "$STUB_DIR/gitleaks-argv"
  grep -qx "api repos/dryvist/nix-ai/git/refs -f ref=refs/heads/agent/zcode/j-1 -f sha=$head" "$STUB_DIR/gh-api.log"
  jq -e --arg h "$head" '.variables.input |
    .branch == {repositoryNameWithOwner: "dryvist/nix-ai", branchName: "agent/zcode/j-1"} and
    .expectedHeadOid == $h and
    .fileChanges.additions == [{path: "tool-file", contents: "Y2hhbmdlCg=="}] and
    .fileChanges.deletions == [{path: "old-file"}] and
    .message.body == "- tool commit"' "$STUB_DIR/graphql.json"
  run ! git -C "$origin" rev-parse --verify -q refs/heads/agent/zcode/j-1
  [ "$(cat "$home/work/.agent-pr-url")" = https://github.com/dryvist/nix-ai/pull/7 ]
}

@test "a gitleaks finding in a tool-made commit stops the publish" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home tools origin
  publish_fixture blocked 1
  bash_stub "$tools/zcode" <<'SH'
echo change >tool-file
git add tool-file
git commit -q -m "tool commit"
SH
  run_publish j-2
  [ "$status" -eq 65 ]
  [ ! -e "$STUB_DIR/graphql.json" ]
  [ ! -e "$STUB_DIR/gh-api.log" ]
}

@test "a file mode change is refused before anything reaches origin" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home tools origin
  publish_fixture mode 0
  bash_stub "$tools/zcode" <<'SH'
chmod +x old-file
git commit -q -am "make it executable"
SH
  run_publish j-3
  [ "$status" -eq 1 ]
  [[ $output == *"old-file changes a file mode or symlink (100644 -> 100755)"* ]]
  [ ! -e "$STUB_DIR/graphql.json" ]
  [ ! -e "$STUB_DIR/gh-api.log" ]
}

@test "a change over the publish size limit fails whole, before anything reaches origin" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home tools origin
  publish_fixture size 0
  bash_stub "$tools/zcode" <<'SH'
head -c 4096 /dev/zero >big-file
git add big-file
git commit -q -m "big"
SH
  run_publish j-4 AGENT_PUBLISH_MAX_BYTES=1024
  [ "$status" -eq 1 ]
  [[ $output == *"larger than 1024 bytes encoded; nothing was published"* ]]
  [ ! -e "$STUB_DIR/graphql.json" ]
  [ ! -e "$STUB_DIR/gh-api.log" ]
}

@test "fix concurrency cap returns busy before login or job creation" {
  export STUB_FIX_RUNNING_COUNT=3
  local prompt
  prompt=$(fix_prompt "repair this failure")
  run --separate-stderr dispatch fix zcode dryvist/nix-ai ci/fix "$FIX_SHA" "$prompt"
  [ "$status" -eq 75 ]
  [ "$output" = '{"error":"busy"}' ]
  [ ! -e "$AGENT_DISPATCH_STATE_DIR" ]
  [ "$(grep -c 'docker ps' "$STUB_DIR/argv.log")" -eq 1 ]
  [ "$(grep -c 'auth/approle/login' "$STUB_DIR/calls.log" || true)" -eq 0 ]
  [ "$(grep -c 'docker create' "$STUB_DIR/argv.log" || true)" -eq 0 ]
}

@test "continue refuses a fix job and status reports its commit field" {
  local prompt id
  prompt=$(fix_prompt "repair this failure")
  run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
  [ "$status" -eq 0 ]
  id=$(jq -r .job <<<"$output")
  jq -e '.mode == "fix" and .branch == "feature/ci-fix" and .expected_sha == $sha and .commit == ""' \
    --arg sha "$FIX_SHA" <<<"$output"
  run --separate-stderr dispatch continue "$id" "another attempt"
  [ "$status" -eq 64 ]
  [[ $stderr == *"fix jobs run once"* ]]
  run --separate-stderr dispatch status "$id"
  [ "$(jq -r .commit <<<"$output")" = "" ]
}

@test "fix container gets no GitHub token and revokes the contents-read token before create" {
  local prompt id env_data rec read_mint write_mint request_body
  set_fix_outputs "$(fix_add_json src/fix.txt 'fixed content')"
  export STUB_CONTENTS_404=1 STUB_FIX_BRANCH_EXISTS=1
  prompt=$(fix_prompt "repair this failure")
  run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = succeeded ]
  [ "$(jq -r .commit <<<"$output")" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]
  id=$(jq -r .job <<<"$output")
  [ "$(jq -r .mode "$AGENT_DISPATCH_STATE_DIR/$id/job.json")" = fix ]
  create_args 1
  has_pair --label agent-dispatch.mode=fix
  has_pair -e AGENT_MODE=fix
  has_pair -e "AGENT_BRANCH=feature/ci-fix"
  has_pair -e "AGENT_EXPECTED_SHA=$FIX_SHA"
  run ! grep -q AGENT_PR_DRAFT "$STUB_DIR/create.1"
  env_data=$(tar -xOf "$STUB_DIR/cp.1.tar" .agent-env)
  [[ ! $env_data =~ GH_TOKEN|GITHUB_TOKEN ]]
  grep -qx 'AGENT_ROUTER_BASE_URL=https://router.test/v1' <<<"$env_data"
  [[ ! $env_data =~ AGENT_ROUTER_KEY ]]
  grep -q 'GET https://bao.test/v1/auth/approle/role/sandbox-agent-read/role-id' "$STUB_DIR/calls.log"
  run ! grep -q 'sandbox-agent-write' "$STUB_DIR/calls.log"
  [ "$(line_of 'DELETE https://api.github.com/installation/token')" -lt "$(line_of 'docker create')" ]
  [ "$(last_line_of 'POST https://bao.test/v1/github-agents/token')" -gt "$(line_of 'docker wait')" ]
  read_mint=""
  write_mint=""
  for rec in "$STUB_DIR"/http.*.req; do
    [ "$(cat "$rec")" = 'POST https://bao.test/v1/github-agents/token' ] || continue
    request_body=$(cat "${rec%.req}.body")
    if jq -e '.permissions == {contents: "read"}' <<<"$request_body" >/dev/null; then
      read_mint=$request_body
    else
      write_mint=$request_body
    fi
  done
  [ -n "$read_mint" ] && [ -n "$write_mint" ]
  jq -e '.permissions == {contents: "read"} and .repositories == "nix-ai"' <<<"$read_mint"
  jq -e '.permissions == {contents: "write", pull_requests: "write"}' <<<"$write_mint"
  grep -qx 'docker rm -f cid0123' "$STUB_DIR/argv.log"
  no_secret_on_a_command_line
}

@test "an empty fix is a successful no-change without minting a write token" {
  local prompt
  prompt=$(fix_prompt "repair this failure")
  export STUB_FIX_BRANCH_EXISTS=1
  run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = no-change ]
  [ "$(jq -r .commit <<<"$output")" = "" ]
  [ "$(grep -c 'POST https://bao.test/v1/github-agents/token' "$STUB_DIR/calls.log")" -eq 1 ]
  [ ! -e "$STUB_DIR/graphql.json" ]
}

@test "existing branch fix creates one commit at expectedHeadOid with headline and trailers" {
  local prompt graphql changes id
  set_fix_outputs "$(fix_add_json src/fix.txt 'fixed content')"
  export STUB_CONTENTS_404=1 STUB_FIX_BRANCH_EXISTS=1
  prompt=$(fix_prompt "repair this failure")
  run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
  [ "$status" -eq 0 ]
  id=$(jq -r .job <<<"$output")
  graphql=$(http_rec 'POST https://api.github.com/graphql')
  jq -e --arg sha "$FIX_SHA" '.variables.input.expectedHeadOid == $sha and
    .variables.input.message.headline == "fix: repair test" and
    .variables.input.message.body == "CI-Resolver-Attempt: 2\nCI-Resolver-Tier: t2\nCI-Resolver-Signature: abcdef012345\n\nAssisted-by: zcode (nix-agent-sandbox)" and
    .variables.input.fileChanges.additions == [{path: "src/fix.txt", contents: "Zml4ZWQgY29udGVudA=="}]' \
    "$graphql.body"
  [ "$(jq -r .commit <<<"$output")" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]
  [ "$(cat "$AGENT_DISPATCH_STATE_DIR/$id/commit")" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]
  [ "$(grep -c 'POST https://api.github.com/graphql' "$STUB_DIR/calls.log")" -eq 1 ]
  [ "$(grep -c 'POST https://api.github.com/repos/dryvist/nix-ai/git/refs' "$STUB_DIR/calls.log" || true)" -eq 0 ]
  [ "$(grep -c 'POST https://api.github.com/repos/dryvist/nix-ai/pulls' "$STUB_DIR/calls.log" || true)" -eq 0 ]
}

@test "new branch fix creates ref at expected sha and a non-draft PR to the API default branch" {
  local prompt graphql ref_request pr_request
  set_fix_outputs "$(fix_add_json src/fix.txt 'fixed content')"
  export STUB_CONTENTS_404=1 STUB_DEFAULT_BRANCH=trunk
  prompt=$(fix_prompt "repair this failure")
  run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/new-fix "$FIX_SHA" "$prompt"
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = succeeded ]
  [ "$(jq -r .pr <<<"$output")" = https://github.com/dryvist/nix-ai/pull/8 ]
  ref_request=$(http_rec 'POST https://api.github.com/repos/dryvist/nix-ai/git/refs')
  jq -e --arg sha "$FIX_SHA" '.ref == "refs/heads/feature/new-fix" and .sha == $sha' "$ref_request.body"
  graphql=$(http_rec 'POST https://api.github.com/graphql')
  jq -e --arg sha "$FIX_SHA" '.variables.input.expectedHeadOid == $sha' "$graphql.body"
  pr_request=$(http_rec 'POST https://api.github.com/repos/dryvist/nix-ai/pulls')
  jq -e '.draft == false and .title == "fix: repair test" and .head == "feature/new-fix" and .base == "trunk"' "$pr_request.body"
}

@test "head moved deletes a newly created branch and leaves no commit or PR" {
  local prompt
  set_fix_outputs "$(fix_add_json src/fix.txt 'fixed content')"
  export STUB_CONTENTS_404=1 STUB_HEAD_MOVED=1
  prompt=$(fix_prompt "repair this failure")
  run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/new-fix "$FIX_SHA" "$prompt"
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = failed ]
  [ "$(jq -r .reason <<<"$output")" = 'head moved' ]
  [ "$(jq -r .commit <<<"$output")" = "" ]
  grep -q 'DELETE https://api.github.com/repos/dryvist/nix-ai/git/refs/heads/feature/new-fix' "$STUB_DIR/calls.log"
  [ "$(grep -c 'POST https://api.github.com/repos/dryvist/nix-ai/pulls' "$STUB_DIR/calls.log" || true)" -eq 0 ]
}

@test "fix diff guards reject workflow changes, test deletions, suppression lines and excess files" {
  local prompt json id state status_json attempt
  prompt=$(fix_prompt "repair this failure")
  for json in \
    "$(fix_add_json '.github/workflows/check.yml' 'name: checks')" \
    "$(fix_delete_json 'src/tests/test_fix.py')"; do
    set_fix_outputs "$json"
    export STUB_CONTENTS_404=1
    run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
    [ "$status" -eq 0 ]
    id=$(jq -r .job <<<"$output")
    for ((attempt = 0; attempt < 100; attempt++)); do
      status_json=$(dispatch status "$id")
      state=$(jq -r .state <<<"$status_json")
      [[ $state == failed ]] && break
      sleep 0.02
    done
    [ "$state" = failed ]
    [[ $(jq -r .reason <<<"$status_json") == guard:* ]]
    [ "$(grep -c 'POST https://api.github.com/graphql' "$STUB_DIR/calls.log" || true)" -eq 0 ]
    [ "$(grep -c 'POST https://api.github.com/repos/dryvist/nix-ai/git/refs' "$STUB_DIR/calls.log" || true)" -eq 0 ]
    rm -rf "$STUB_DIR/fix"
  done

  set_fix_outputs "$(fix_add_json 'src/fix.py' $'flag = True  # noqa\n')"
  export STUB_CONTENTS_404=1
  run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
  [ "$status" -eq 0 ]
  [ "$(jq -r .reason <<<"$output")" = 'guard: suppression line' ]
  [ "$(grep -c 'POST https://api.github.com/graphql' "$STUB_DIR/calls.log" || true)" -eq 0 ]

  rm -rf "$STUB_DIR/fix"
  json=$(jq -cn '{additions: [range(0; 21) | {path: ("src/file" + tostring), contents: "eA=="}], deletions: []}')
  set_fix_outputs "$json"
  run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
  [ "$status" -eq 0 ]
  [ "$(jq -r .reason <<<"$output")" = 'guard: too many files' ]
  [ "$(grep -c 'POST https://api.github.com/graphql' "$STUB_DIR/calls.log" || true)" -eq 0 ]
}

@test "fix refuses additions that remove test definitions from an existing test file" {
  local prompt base
  prompt=$(fix_prompt "repair the tests")
  base=$(printf 'def test_one():\n    assert True\ndef test_two():\n    assert True\n' | base64 | tr -d '\n')
  export STUB_BASE_CONTENT="$base"
  set_fix_outputs "$(fix_add_json tests/test_fixture.py $'def test_one():\n    pass\n')"
  run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
  [ "$status" -eq 0 ]
  [ "$(jq -r .reason <<<"$output")" = 'guard: test removal' ]
  [ "$(grep -c 'POST https://api.github.com/graphql' "$STUB_DIR/calls.log" || true)" -eq 0 ]
  [ "$(grep -c 'POST https://api.github.com/repos/dryvist/nix-ai/git/refs' "$STUB_DIR/calls.log" || true)" -eq 0 ]
}

@test "fix refuses delivered profile and router credential values in additions" {
  local prompt dispatcher json job state attempts
  dispatcher=$(make_dispatcher '{"zcode":{"env":["ZAI_SUBSCRIPTION_KEY"],"routerKeyField":"ZCODE_ROUTER_KEY"}}')
  prompt=$(fix_prompt "repair this failure")
  export STUB_CONTENTS_404=1
  for json in \
    "$(fix_add_json src/credential.txt 'prefix zai-secret-value suffix')" \
    "$(fix_add_json src/credential.txt 'prefix zcode-router-secret-value suffix')" \
    "$(fix_add_json docs/endpoint.md 'base: https://router.test/v1')"; do
    set_fix_outputs "$json"
    run --separate-stderr "$dispatcher" fix zcode dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
    [ "$status" -eq 0 ]
    job=$(jq -r .job <<<"$output")
    state=running attempts=0
    while [ "$state" = running ] && [ "$attempts" -lt 100 ]; do
      sleep 0.02
      run --separate-stderr "$dispatcher" status "$job"
      [ "$status" -eq 0 ]
      state=$(jq -r .state <<<"$output")
      attempts=$((attempts + 1))
    done
    [ "$state" = failed ]
    [ "$(jq -r .reason <<<"$output")" = 'guard: credential value' ]
    [ "$(grep -c 'POST https://api.github.com/graphql' "$STUB_DIR/calls.log" || true)" -eq 0 ]
    [ "$(grep -c 'POST https://api.github.com/repos/dryvist/nix-ai/git/refs' "$STUB_DIR/calls.log" || true)" -eq 0 ]
    rm -rf "$STUB_DIR/fix"
  done
}

@test "fix scans the decoded additions with host gitleaks before publishing" {
  local prompt
  prompt=$(fix_prompt "repair this failure")
  set_fix_outputs "$(fix_add_json src/deep/fix.txt 'fixed content')"
  export STUB_CONTENTS_404=1
  run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = succeeded ]
  [ "$(cat "$STUB_DIR/scan.list")" = ./src/deep/fix.txt ]
  grep -E '^docker run .*--network none .*--read-only .*--cap-drop ALL .*--entrypoint gitleaks .* dir /scan' "$STUB_DIR/argv.log"
  [ "$(line_of 'docker run')" -lt "$(line_of 'POST https://api.github.com/graphql')" ]

  rm -rf "$STUB_DIR/fix"
  export STUB_GITLEAKS_FAIL=1
  set_fix_outputs "$(fix_add_json src/fix.txt 'fixed content')"
  run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
  [ "$status" -eq 0 ]
  [ "$(jq -r .reason <<<"$output")" = 'guard: gitleaks' ]
  [ "$(grep -c 'POST https://api.github.com/graphql' "$STUB_DIR/calls.log" || true)" -eq 1 ]
}

@test "fix refuses multi-document changes.json before publishing either document" {
  local prompt malicious benign
  prompt=$(fix_prompt "repair this failure")
  malicious=$(fix_add_json .github/workflows/evil.yml 'name: malicious')
  benign=$(fix_add_json src/fix.txt 'benign')
  set_fix_outputs "$malicious"$'\n'"$benign"
  export STUB_CONTENTS_404=1
  run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
  [ "$status" -eq 0 ]
  [ "$(jq -r .reason <<<"$output")" = 'guard: invalid changes.json' ]
  [ "$(grep -c 'POST https://api.github.com/graphql' "$STUB_DIR/calls.log" || true)" -eq 0 ]
  [ "$(grep -c 'POST https://api.github.com/repos/dryvist/nix-ai/git/refs' "$STUB_DIR/calls.log" || true)" -eq 0 ]
}

@test "fix refuses every .github path and distinguishes workflows" {
  local prompt json reason
  prompt=$(fix_prompt "repair this failure")
  for json in \
    "$(fix_add_json .github/CODEOWNERS 'example')" \
    "$(fix_delete_json .github/PULL_REQUEST_TEMPLATE.md)" \
    "$(fix_delete_json .github/workflows/check.yml)"; do
    set_fix_outputs "$json"
    export STUB_CONTENTS_404=1
    run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
    [ "$status" -eq 0 ]
    reason=$(jq -r .reason <<<"$output")
    case "$json" in
      *workflows*) [ "$reason" = 'guard: workflow path' ] ;;
      *) [ "$reason" = 'guard: github path' ] ;;
    esac
    [ "$(grep -c 'POST https://api.github.com/graphql' "$STUB_DIR/calls.log" || true)" -eq 0 ]
    [ "$(grep -c 'POST https://api.github.com/repos/dryvist/nix-ai/git/refs' "$STUB_DIR/calls.log" || true)" -eq 0 ]
    rm -rf "$STUB_DIR/fix"
  done
}

@test "fix rejects new suppression forms and base files larger than the contents API limit" {
  local prompt json
  prompt=$(fix_prompt "repair this failure")
  export STUB_CONTENTS_404=1
  for json in \
    "$(fix_add_json src/fix.py 'value = 1  #   type: ignore[assignment]')" \
    "$(fix_add_json src/fix.sh 'set +e')" \
    "$(fix_add_json src/fix.sh 'command || exit 0')" \
    "$(fix_add_json tests/test_fix.py '@pytest.mark.skip')" \
    "$(fix_add_json tests/test_fix.py 'pytest.mark.xfail')"; do
    set_fix_outputs "$json"
    run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
    [ "$status" -eq 0 ]
    [ "$(jq -r .reason <<<"$output")" = 'guard: suppression line' ]
    [ "$(grep -c 'POST https://api.github.com/graphql' "$STUB_DIR/calls.log" || true)" -eq 0 ]
    rm -rf "$STUB_DIR/fix"
  done

  unset STUB_CONTENTS_404
  export STUB_BASE_TOO_LARGE=1
  set_fix_outputs "$(fix_add_json src/fix.txt 'change')"
  run --separate-stderr dispatch fix zcode dryvist/nix-ai feature/ci-fix "$FIX_SHA" "$prompt"
  [ "$status" -eq 0 ]
  [ "$(jq -r .reason <<<"$output")" = 'guard: base file too large' ]
  [ "$(grep -c 'POST https://api.github.com/graphql' "$STUB_DIR/calls.log" || true)" -eq 0 ]
}

@test "the entrypoint preserves a failed tool exit and skips publication" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/failed-tool-home" tools="$BATS_TEST_TMPDIR/failed-tool-tools"
  mkdir -p "$home" "$tools"
  printf '%s\n' '{"zcode":{"env":[]}}' >"$home/.agent-profiles.json"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  bash_stub "$tools/zcode" <<'SH'
exit 37
SH
  run env -i PATH="$tools:$PATH" HOME="$home" AGENT_SANDBOX=1 \
    AGENT_TOOL=zcode AGENT_PROMPT='Review this change' bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 37 ]
  [[ $output == *"exited with status 37; refusing to publish"* ]]
}

@test "dispatched tools unwrap AppRole and receive leaf-backed MCP config" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/sandbox-mcp-home" tools="$BATS_TEST_TMPDIR/sandbox-mcp-tools"
  local tool tool_cmd config real_jq
  mkdir -p "$home" "$tools"
  real_jq=$(command -v jq)
  jq -n '{
    zcode:{env:[],sandboxRouterKeyField:"router_key",ttyLogin:true},
    opencode:{env:[],sandboxRouterKeyField:"router_key"},
    "opencode-local":{env:[],sandboxRouterKeyField:"router_key"},
    "qwen-code":{env:[],sandboxRouterKeyField:"router_key"}
  }' >"$home/.agent-profiles.json"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  bash_stub "$tools/curl" <<'SH'
set -euo pipefail
method=GET url= headers= body=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    -H) headers+="$(cat "${2#@}")"; shift 2 ;;
    --data-binary) body=$(cat "${2#@}"); shift 2 ;;
    --max-time) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
case "$url" in
  */v1/sys/wrapping/unwrap)
    [[ $method == POST && $headers == *'sandbox-agent-wrapped-id-value'* ]] || exit 1
    printf '%s\n' '{"data":{"secret_id":"sandbox-secret-id-fixture"}}'
    ;;
  */v1/auth/approle/login)
    [[ $method == POST ]] || exit 1
    jq -e '.role_id == "sandbox-agent-role-id-value" and .secret_id == "sandbox-secret-id-fixture"' \
      <<<"$body" >/dev/null || exit 1
    printf '%s\n' '{"auth":{"client_token":"sandbox-token-fixture"}}'
    ;;
  */v1/secret/data/apps/sandbox-agent)
    [[ $method == GET && $headers == *'sandbox-token-fixture'* ]] || exit 1
    cat "$BATS_TEST_DIRNAME/fixtures/sandbox-agent.json"
    ;;
  */v1/auth/token/revoke-self)
    [[ $method == POST && $headers == *'sandbox-token-fixture'* ]] || exit 1
    printf '%s\n' '{}'
    ;;
  *) exit 1 ;;
esac
SH
  bash_stub "$tools/jq" <<'SH'
case " $* " in
  *vikunja-secret-value*|*zammad-secret-value*|*sandbox-router-secret-value*)
    echo "credential argument detected" >&2
    exit 91
    ;;
esac
exec "$REAL_JQ" "$@"
SH
  for tool in zcode opencode qwen-code; do
    tool_cmd=$tool
    [ "$tool" != qwen-code ] || tool_cmd=qwen
    bash_stub "$tools/$tool_cmd" <<'SH'
set -euo pipefail
test -z "${SANDBOX_ROLE_ID:-}"
test -z "${SANDBOX_WRAPPED_SECRET_ID:-}"
test -z "${VIKUNJA_API_TOKEN:-}"
test -z "${ZAMMAD_HTTP_TOKEN:-}"
test -z "${AGENT_ROUTER_KEY:-}"
test -z "${ZAI_SUBSCRIPTION_KEY:-}"
case "$AGENT_TOOL" in
  zcode) root=mcpServers env_key=env config="$HOME/.zcode/cli/config.json" ;;
  opencode) root=mcp env_key=environment config="$HOME/.config/opencode/opencode.json" ;;
  qwen-code) root=mcpServers env_key=env config="$HOME/.qwen/settings.json" ;;
esac
jq -e --arg root "$root" --arg env_key "$env_key" \
  --arg vik "${AGENT_MCP_VIKUNJA_COMMAND}" --arg zam "${AGENT_MCP_ZAMMAD_COMMAND}" \
  --slurpfile leaf "$BATS_TEST_DIRNAME/fixtures/sandbox-agent.json" \
  '.[$root].vikunja as $v | .[$root].zammad as $z |
   (($v.command == $vik) or ($v.command == [$vik])) and
   (($z.command == $zam) or ($z.command == [$zam])) and
   (($v.args == []) or ($v.args == null)) and
   (($z.args == []) or ($z.args == null)) and
   $v[$env_key].VIKUNJA_API_TOKEN == $leaf[0].data.data.vikunja_token and
   $z[$env_key].ZAMMAD_HTTP_TOKEN == $leaf[0].data.data.zammad_token' \
  "$config" >/dev/null
 [ "$(ls -l "$config" | cut -c2-10)" = rw------- ]
 case "$AGENT_TOOL" in
   zcode)
     jq -e --slurpfile leaf "$BATS_TEST_DIRNAME/fixtures/sandbox-agent.json" \
       '.config.providerConfigRules.providerRules[0].config.access.apiKey == $leaf[0].data.data.router_key' \
       "$HOME/.zcode/v2/provider_config.json" >/dev/null
     [ "$(ls -l "$HOME/.zcode/v2/provider_config.json" | cut -c2-10)" = rw------- ]
     ;;
   opencode)
     jq -e --slurpfile leaf "$BATS_TEST_DIRNAME/fixtures/sandbox-agent.json" \
       '.provider["agent-router"].options.apiKey == $leaf[0].data.data.router_key' "$config" >/dev/null
     ;;
   qwen-code) test -n "${OPENAI_API_KEY:-}" ;;
 esac
SH
    cat >"$home/.agent-env" <<'EOF'
BAO_ADDR=https://bao.test
SANDBOX_ROLE_ID=sandbox-agent-role-id-value
SANDBOX_WRAPPED_SECRET_ID=sandbox-agent-wrapped-id-value
GIT_MIRROR_URL=https://mirror.test/public
VIKUNJA_URL=https://vikunja.test/api/v1
ZAMMAD_URL=https://zammad.test/api/v1
AGENT_ROUTER_BASE_URL=https://router.test/v1
EOF
    chmod 600 "$home/.agent-env"
    run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$STUB_DIR" \
      BATS_TEST_DIRNAME="$BATS_TEST_DIRNAME" AGENT_SANDBOX=1 AGENT_DISPATCHED_JOB=1 \
      AGENT_TOOL="$tool" AGENT_PROMPT='Use MCP tools' REAL_JQ="$real_jq" \
      AGENT_MCP_VIKUNJA_COMMAND=/nix/store/vikunja-mcp/bin/vikunja-mcp \
      AGENT_MCP_ZAMMAD_COMMAND=/nix/store/zammad-mcp/bin/sandbox-zammad-mcp \
      AGENT_MCP_ZAMMAD_ARGS='[]' bash -euo pipefail "$ENTRYPOINT"
    [ "$status" -eq 0 ]
    [[ $output != *sandbox-token-fixture* && $output != *sandbox-secret-id-fixture* ]]
    case "$tool" in
      zcode) [ ! -e "$home/.zcode/cli/config.json" ] ;;
      opencode) [ ! -e "$home/.config/opencode/opencode.json" ] ;;
      qwen-code) [ ! -e "$home/.qwen/settings.json" ] ;;
    esac
  done
}
