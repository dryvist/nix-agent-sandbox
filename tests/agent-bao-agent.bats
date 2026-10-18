#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

teardown() {
  if [ -n "${BAO_SERVER_PID:-}" ]; then
    kill "$BAO_SERVER_PID" 2>/dev/null || true
    wait "$BAO_SERVER_PID" 2>/dev/null || true
  fi
}

bash_stub() {
  { printf '#!%s\n' "$BASH"; cat; } >"$1"
  chmod +x "$1"
}

# The bao stub checks the launcher contract without contacting a server.
# The dev-server test uses BAO_BIN when OpenBao is available.

@test "entrypoint writes protected AppRole inputs and selects the Agent role config" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/home" tools="$BATS_TEST_TMPDIR/bin"
  local auth_dir="$BATS_TEST_TMPDIR/auth" mode expected_config
  mkdir -p "$home" "$tools" "$auth_dir"
  printf '%s\n' '{"zcode":{"env":[],"sandboxRouterKeyField":"router_key"}}' \
    >"$home/.agent-profiles.json"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  bash_stub "$tools/bao" <<'SH'
set -euo pipefail
test "$1" = agent
test "$2" = "-config=/etc/openbao-agent/${EXPECTED_CONFIG}.hcl"
test -z "${SANDBOX_ROLE_ID:-}"
test -z "${SANDBOX_WRAPPED_SECRET_ID:-}"
test "${BAO_ADDR}" = https://bao.test
test "$(cat "$STUB_AUTH_DIR/role-id")" = role-id-test
test "$(cat "$STUB_AUTH_DIR/wrapped-secret-id")" = wrapped-secret-id-test
test "$(ls -l "$STUB_AUTH_DIR/role-id" | cut -c2-10)" = rw-------
test "$(ls -l "$STUB_AUTH_DIR/wrapped-secret-id" | cut -c2-10)" = rw-------
printf '%s\n' "$2" >>"$STUB_DIR/configs"
SH

  for mode in start fix; do
    if [ "$mode" = fix ]; then
      expected_config="read"
    else
      expected_config="write"
    fi
    run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$BATS_TEST_TMPDIR" \
      STUB_AUTH_DIR="$auth_dir" AGENT_SANDBOX=1 AGENT_DISPATCHED_JOB=1 \
      AGENT_TOOL=zcode AGENT_PROFILE=zcode AGENT_MODE="$mode" \
      AGENT_PROMPT='Inspect the repository' BAO_ADDR=https://bao.test \
      SANDBOX_ROLE_ID=role-id-test SANDBOX_WRAPPED_SECRET_ID=wrapped-secret-id-test \
      AGENT_OPENBAO_AUTH_DIR="$auth_dir" EXPECTED_CONFIG="$expected_config" \
      AGENT_BRANCH=task AGENT_REPO=example/repo \
      AGENT_EXPECTED_SHA=0000000000000000000000000000000000000000 \
      bash -euo pipefail "$ENTRYPOINT"
    [ "$status" -eq 0 ]
    [ ! -e "$auth_dir/role-id" ]
    [ ! -e "$auth_dir/wrapped-secret-id" ]
  done
  [ "$(wc -l <"$BATS_TEST_TMPDIR/configs" | tr -d ' ')" = 2 ]
}

@test "entrypoint delegates missing AppRole inputs to OpenBao Agent" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/missing-home" tools="$BATS_TEST_TMPDIR/missing-bin"
  local auth_dir="$BATS_TEST_TMPDIR/missing-auth"
  mkdir -p "$home" "$tools" "$auth_dir"
  printf '%s\n' '{"zcode":{"env":[]}}' >"$home/.agent-profiles.json"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  bash_stub "$tools/bao" <<'SH'
test "$1" = agent
test "$2" = -config=/etc/openbao-agent/write.hcl
test ! -s "$STUB_AUTH_DIR/role-id"
test ! -s "$STUB_AUTH_DIR/wrapped-secret-id"
test "$(ls -l "$STUB_AUTH_DIR/role-id" | cut -c2-10)" = rw-------
test "$(ls -l "$STUB_AUTH_DIR/wrapped-secret-id" | cut -c2-10)" = rw-------
exit 42
SH
  run env -i PATH="$tools:$PATH" HOME="$home" STUB_AUTH_DIR="$auth_dir" \
    AGENT_SANDBOX=1 AGENT_DISPATCHED_JOB=1 AGENT_TOOL=zcode AGENT_PROFILE=zcode \
    AGENT_PROMPT='Inspect the repository' BAO_ADDR=https://bao.test \
    AGENT_OPENBAO_AUTH_DIR="$auth_dir" bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 42 ]
  [ ! -e "$auth_dir/role-id" ]
  [ ! -e "$auth_dir/wrapped-secret-id" ]
}

@test "entrypoint selects public configs only for a batch profile without trackers" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/public-home" tools="$BATS_TEST_TMPDIR/public-bin"
  local auth_dir="$BATS_TEST_TMPDIR/public-auth" mode expected_config
  mkdir -p "$home" "$tools" "$auth_dir"
  printf '%s\n' '{"zcode":{"env":[],"sandboxRouterKeyField":"router_key","trackerAccess":false,"ttyLogin":true}}' \
    >"$home/.agent-profiles.json"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  bash_stub "$tools/bao" <<'SH'
test "$1" = agent
test "$2" = "-config=/etc/openbao-agent/${EXPECTED_CONFIG}.hcl"
SH
  for mode in start fix; do
    if [ "$mode" = fix ]; then
      expected_config=read-public
    else
      expected_config=write-public
    fi
    run env -i PATH="$tools:$PATH" HOME="$home" AGENT_SANDBOX=1 AGENT_DISPATCHED_JOB=1 \
      AGENT_TOOL=zcode AGENT_PROFILE=zcode AGENT_MODE="$mode" AGENT_PROMPT='Inspect the repository' \
      BAO_ADDR=https://bao.test SANDBOX_ROLE_ID=role-id-test \
      SANDBOX_WRAPPED_SECRET_ID=wrapped-secret-id-test AGENT_OPENBAO_AUTH_DIR="$auth_dir" \
      EXPECTED_CONFIG="$expected_config" AGENT_REPO=example/repo AGENT_BRANCH=task \
      AGENT_EXPECTED_SHA=0000000000000000000000000000000000000000 \
      bash -euo pipefail "$ENTRYPOINT"
    [ "$status" -eq 0 ]
  done
  run env -i PATH="$tools:$PATH" HOME="$home" AGENT_SANDBOX=1 AGENT_DISPATCHED_JOB=1 \
    AGENT_TOOL=zcode AGENT_PROFILE=zcode AGENT_MODE=start AGENT_TTY=1 \
    AGENT_PROMPT='Inspect the repository' BAO_ADDR=https://bao.test \
    SANDBOX_ROLE_ID=role-id-test SANDBOX_WRAPPED_SECRET_ID=wrapped-secret-id-test \
    AGENT_OPENBAO_AUTH_DIR="$auth_dir" EXPECTED_CONFIG=write \
    bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 0 ]
}

@test "entrypoint refuses a malformed trackerAccess value" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/malformed-profile-home" tools="$BATS_TEST_TMPDIR/malformed-profile-bin"
  mkdir -p "$home" "$tools"
  printf '%s\n' '{"zcode":{"env":[],"trackerAccess":"false"}}' >"$home/.agent-profiles.json"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  bash_stub "$tools/bao" <<'SH'
touch "$STUB_DIR/bao-ran"
SH
  run env -i PATH="$tools:$PATH" HOME="$home" STUB_DIR="$BATS_TEST_TMPDIR" \
    AGENT_SANDBOX=1 AGENT_DISPATCHED_JOB=1 AGENT_TOOL=zcode AGENT_PROFILE=zcode \
    AGENT_PROMPT='Inspect the repository' BAO_ADDR=https://bao.test \
    SANDBOX_ROLE_ID=role-id-test SANDBOX_WRAPPED_SECRET_ID=wrapped-secret-id-test \
    bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 64 ]
  [[ $output == *"trackerAccess must be boolean"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/bao-ran" ]
}

@test "OpenBao Agent consumes a wrapped SecretID and injects KV templates" {
  if [ -z "${BAO_BIN:-}" ]; then
    skip "BAO_BIN is not included in the current Bats test environment"
  fi

  local worktree="$PWD" auth_dir="$BATS_TEST_TMPDIR/auth"
  local port address role_id wrapped_id root_token=agent-test-root-token
  local config="$BATS_TEST_TMPDIR/agent.hcl" public_config="$BATS_TEST_TMPDIR/agent-public.hcl"
  local child="$BATS_TEST_TMPDIR/verify-env"
  local agent_output agent_status value
  mkdir -p "$auth_dir"
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
  address="http://127.0.0.1:${port}"
  BAO_ADDR="$address" "$BAO_BIN" server -dev -dev-no-store-token \
    -dev-root-token-id="$root_token" -dev-listen-address="127.0.0.1:${port}" \
    >"$BATS_TEST_TMPDIR/server.log" 2>&1 &
  BAO_SERVER_PID=$!
  for _ in {1..100}; do
    if "$BAO_BIN" status -address="$address" >/dev/null 2>&1; then break; fi
    sleep 0.1
  done
  "$BAO_BIN" status -address="$address" >/dev/null || { tail -n 20 "$BATS_TEST_TMPDIR/server.log" >&2; false; }

  BAO_ADDR="$address" BAO_TOKEN="$root_token" "$BAO_BIN" auth enable approle >/dev/null
  BAO_ADDR="$address" BAO_TOKEN="$root_token" "$BAO_BIN" policy write sandbox-read - <<'HCL' >/dev/null
path "secret/data/apps/sandbox-agent" {
  capabilities = ["read"]
}
HCL
  BAO_ADDR="$address" BAO_TOKEN="$root_token" "$BAO_BIN" kv put \
    secret/apps/sandbox-agent router_key=router-test-key \
    vikunja_token=vikunja-test-token zammad_token=zammad-test-token >/dev/null
  BAO_ADDR="$address" BAO_TOKEN="$root_token" "$BAO_BIN" write \
    auth/approle/role/sandbox-agent-read token_policies=sandbox-read \
    token_ttl=15m token_max_ttl=15m secret_id_num_uses=1 >/dev/null
  role_id=$(BAO_ADDR="$address" BAO_TOKEN="$root_token" "$BAO_BIN" \
    read -field=role_id auth/approle/role/sandbox-agent-read/role-id)
  wrapped_id=$(BAO_ADDR="$address" BAO_TOKEN="$root_token" "$BAO_BIN" \
    write -wrap-ttl=2m -f -format=json \
    auth/approle/role/sandbox-agent-read/secret-id | jq -er '.wrap_info.token')
  printf '%s' "$role_id" >"$auth_dir/role-id"
  printf '%s' "$wrapped_id" >"$auth_dir/wrapped-secret-id"
  chmod 600 "$auth_dir/role-id" "$auth_dir/wrapped-secret-id"

  cat >"$child" <<'SH'
#!/bin/sh
set -eu
test -z "${SANDBOX_ROLE_ID:-}"
test -z "${SANDBOX_WRAPPED_SECRET_ID:-}"
case "$AGENT_TOOL" in
  zcode)
    test "$AGENT_ROUTER_KEY" = "$BAO_TEST_ROUTER_KEY"
    test -z "${VIKUNJA_API_TOKEN:-}"
    test -z "${ZAMMAD_HTTP_TOKEN:-}"
    if [ "${EXPECT_PUBLIC:-}" = 1 ]; then
      printf '%s' "$ZCODE_MCP_CONFIG" | jq -e '.mcp.servers == {}' >/dev/null
    else
      printf '%s' "$ZCODE_MCP_CONFIG" | jq -e '
        .mcp.servers.vikunja.command == "/bin/vikunja-mcp" and
        .mcp.servers.zammad.command == "/bin/sandbox-zammad-mcp" and
        .mcp.servers.vikunja.env.VIKUNJA_API_TOKEN == env.BAO_TEST_VIKUNJA_TOKEN and
        .mcp.servers.zammad.env.ZAMMAD_HTTP_TOKEN == env.BAO_TEST_ZAMMAD_TOKEN
      ' >/dev/null
    fi
    ;;
  opencode)
    test "$AGENT_ROUTER_KEY" = "$BAO_TEST_ROUTER_KEY"
    test "$VIKUNJA_API_TOKEN" = "$BAO_TEST_VIKUNJA_TOKEN"
    test "$ZAMMAD_HTTP_TOKEN" = "$BAO_TEST_ZAMMAD_TOKEN"
    printf '%s' "$OPENCODE_CONFIG_CONTENT" | jq -e '
      .mcp.vikunja.environment.VIKUNJA_API_TOKEN == "{env:VIKUNJA_API_TOKEN}" and
      .mcp.zammad.environment.ZAMMAD_HTTP_TOKEN == "{env:ZAMMAD_HTTP_TOKEN}" and
      .provider["agent-router"].options.apiKey == "{env:AGENT_ROUTER_KEY}"
    ' >/dev/null
    ;;
esac
SH
  chmod 700 "$child"
  sed \
    -e "s#@AGENT_ENTRYPOINT@#${child}#" \
    -e "s#/dev/shm/agent-openbao#${auth_dir}#g" \
    -e "s#/etc/openbao-agent/templates#${worktree}/templates/bao-agent#g" \
    "$worktree/templates/bao-agent/read.hcl" >"$config"
  sed \
    -e "s#@AGENT_ENTRYPOINT@#${child}#" \
    -e "s#/dev/shm/agent-openbao#${auth_dir}#g" \
    -e "s#/etc/openbao-agent/templates#${worktree}/templates/bao-agent#g" \
    "$worktree/templates/bao-agent/read-public.hcl" >"$public_config"

  agent_status=0
  agent_output=$(BAO_ADDR="$address" AGENT_TOOL=zcode \
    AGENT_SANDBOX_ROUTER_KEY_FIELD=router_key \
    AGENT_MCP_VIKUNJA_COMMAND=/bin/vikunja-mcp \
    AGENT_MCP_ZAMMAD_COMMAND=/bin/sandbox-zammad-mcp AGENT_MCP_ZAMMAD_ARGS='[]' \
    BAO_TEST_ROUTER_KEY=router-test-key \
    BAO_TEST_VIKUNJA_TOKEN=vikunja-test-token \
    BAO_TEST_ZAMMAD_TOKEN=zammad-test-token \
    "$BAO_BIN" agent -config="$config" 2>&1) || agent_status=$?
  if [ "$agent_status" -ne 0 ]; then
    for value in "$root_token" "$role_id" "$wrapped_id" router-test-key \
      vikunja-test-token zammad-test-token; do
      agent_output=${agent_output//"$value"/[REDACTED]}
    done
    printf '%s\n' "$agent_output" | sed -E 's/[[:alnum:]_-]{16,}/[REDACTED]/g'
    return "$agent_status"
  fi
  [ ! -e "$auth_dir/wrapped-secret-id" ]

  wrapped_id=$(BAO_ADDR="$address" BAO_TOKEN="$root_token" "$BAO_BIN" \
    write -wrap-ttl=2m -f -format=json \
    auth/approle/role/sandbox-agent-read/secret-id | jq -er '.wrap_info.token')
  printf '%s' "$role_id" >"$auth_dir/role-id"
  printf '%s' "$wrapped_id" >"$auth_dir/wrapped-secret-id"
  chmod 600 "$auth_dir/role-id" "$auth_dir/wrapped-secret-id"
  agent_status=0
  agent_output=$(BAO_ADDR="$address" AGENT_TOOL=opencode \
    AGENT_SANDBOX_ROUTER_KEY_FIELD=router_key \
    AGENT_ROUTER_BASE_URL=https://router.test/v1 \
    AGENT_MCP_VIKUNJA_COMMAND=/bin/vikunja-mcp \
    AGENT_MCP_ZAMMAD_COMMAND=/bin/sandbox-zammad-mcp AGENT_MCP_ZAMMAD_ARGS='[]' \
    BAO_TEST_ROUTER_KEY=router-test-key \
    BAO_TEST_VIKUNJA_TOKEN=vikunja-test-token \
    BAO_TEST_ZAMMAD_TOKEN=zammad-test-token \
    "$BAO_BIN" agent -config="$config" 2>&1) || agent_status=$?
  if [ "$agent_status" -ne 0 ]; then
    for value in "$root_token" "$role_id" "$wrapped_id" router-test-key \
      vikunja-test-token zammad-test-token; do
      agent_output=${agent_output//"$value"/[REDACTED]}
    done
    printf '%s\n' "$agent_output" | sed -E 's/[[:alnum:]_-]{16,}/[REDACTED]/g'
    return "$agent_status"
  fi
  [ ! -e "$auth_dir/wrapped-secret-id" ]

  wrapped_id=$(BAO_ADDR="$address" BAO_TOKEN="$root_token" "$BAO_BIN" \
    write -wrap-ttl=2m -f -format=json \
    auth/approle/role/sandbox-agent-read/secret-id | jq -er '.wrap_info.token')
  printf '%s' "$role_id" >"$auth_dir/role-id"
  printf '%s' "$wrapped_id" >"$auth_dir/wrapped-secret-id"
  chmod 600 "$auth_dir/role-id" "$auth_dir/wrapped-secret-id"
  agent_status=0
  agent_output=$(BAO_ADDR="$address" AGENT_TOOL=zcode EXPECT_PUBLIC=1 \
    AGENT_SANDBOX_ROUTER_KEY_FIELD=router_key BAO_TEST_ROUTER_KEY=router-test-key \
    "$BAO_BIN" agent -config="$public_config" 2>&1) || agent_status=$?
  if [ "$agent_status" -ne 0 ]; then
    for value in "$root_token" "$role_id" "$wrapped_id" router-test-key; do
      agent_output=${agent_output//"$value"/[REDACTED]}
    done
    printf '%s\n' "$agent_output" | sed -E 's/[[:alnum:]_-]{16,}/[REDACTED]/g'
    return "$agent_status"
  fi
  [ ! -e "$auth_dir/wrapped-secret-id" ]
}

@test "ZCode MCP configuration is private and removed after a dispatched job" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/zcode-home" tools="$BATS_TEST_TMPDIR/zcode-tools"
  local config='{"mcp":{"servers":{"vikunja":{"env":{"VIKUNJA_API_TOKEN":"vikunja-test-token"}},"zammad":{"env":{"ZAMMAD_HTTP_TOKEN":"zammad-test-token"}}}}}'
  mkdir -p "$home" "$tools"
  printf '%s\n' '{"zcode":{"env":[]}}' >"$home/.agent-profiles.json"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  bash_stub "$tools/zcode" <<'SH'
jq -e '.mcp.servers.vikunja.env.VIKUNJA_API_TOKEN == "vikunja-test-token" and
  .mcp.servers.zammad.env.ZAMMAD_HTTP_TOKEN == "zammad-test-token"' \
  "$HOME/.zcode/cli/config.json" >/dev/null
test "$(ls -l "$HOME/.zcode/cli/config.json" | cut -c2-10)" = rw-------
SH
  run env -i PATH="$tools:$PATH" HOME="$home" AGENT_SANDBOX=1 \
    AGENT_DISPATCHED_JOB=1 AGENT_OPENBAO_CHILD=1 AGENT_TOOL=zcode \
    AGENT_PROMPT='Inspect the repository' ZCODE_MCP_CONFIG="$config" \
    bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ ! -e "$home/.zcode/cli/config.json" ]
}

@test "public ZCode MCP configuration contains no servers and is removed after a dispatched job" {
  : "${ENTRYPOINT:?set ENTRYPOINT to scripts/entrypoint.sh}"
  local home="$BATS_TEST_TMPDIR/zcode-public-home" tools="$BATS_TEST_TMPDIR/zcode-public-tools"
  mkdir -p "$home" "$tools"
  printf '%s\n' '{"zcode":{"env":[],"trackerAccess":false}}' >"$home/.agent-profiles.json"
  bash_stub "$tools/id" <<'SH'
echo 1000
SH
  bash_stub "$tools/zcode" <<'SH'
jq -e '.mcp.servers == {}' "$HOME/.zcode/cli/config.json" >/dev/null
test "$(ls -l "$HOME/.zcode/cli/config.json" | cut -c2-10)" = rw-------
SH
  run env -i PATH="$tools:$PATH" HOME="$home" AGENT_SANDBOX=1 \
    AGENT_DISPATCHED_JOB=1 AGENT_OPENBAO_CHILD=1 AGENT_TOOL=zcode \
    AGENT_PROMPT='Inspect the repository' ZCODE_MCP_CONFIG='{"mcp":{"servers":{}}}' \
    bash -euo pipefail "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ ! -e "$home/.zcode/cli/config.json" ]
}

@test "Zammad MCP wrapper invokes the packaged command without uvx" {
  local wrapper="${ZAMMAD_MCP_WRAPPER_SOURCE:?}"
  run grep -Fq uvx "${wrapper}"
  [ "$status" -eq 1 ]
  grep -Fq 'exec env -u PYTHONPATH -u PYTHONHOME mcp-zammad "$@"' "${wrapper}"
}
