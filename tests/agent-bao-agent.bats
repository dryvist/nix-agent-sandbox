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
      expected_config=read
    else
      expected_config=write
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

@test "OpenBao Agent consumes a wrapped SecretID and injects KV templates" {
  if [ -z "${BAO_BIN:-}" ]; then
    skip "BAO_BIN is not included in the current Bats test environment"
  fi

  local worktree="$PWD" auth_dir="$BATS_TEST_TMPDIR/auth"
  local port address role_id wrapped_id root_token=agent-test-root-token
  local config="$BATS_TEST_TMPDIR/agent.hcl" child="$BATS_TEST_TMPDIR/verify-env"
  mkdir -p "$auth_dir"
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
  address="http://127.0.0.1:${port}"
  BAO_ADDR="$address" "$BAO_BIN" server -dev \
    -dev-root-token-id="$root_token" -dev-listen-address="127.0.0.1:${port}" \
    >/dev/null 2>&1 &
  BAO_SERVER_PID=$!
  for _ in {1..60}; do
    if "$BAO_BIN" status -address="$address" >/dev/null 2>&1; then break; fi
    sleep 0.1
  done
  "$BAO_BIN" status -address="$address" >/dev/null

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
    write -wrap-ttl=2m -f -field=wrap_info.token \
    auth/approle/role/sandbox-agent-read/secret-id)
  printf '%s' "$role_id" >"$auth_dir/role-id"
  printf '%s' "$wrapped_id" >"$auth_dir/wrapped-secret-id"
  chmod 600 "$auth_dir/role-id" "$auth_dir/wrapped-secret-id"

  printf '%s\n' '#!/bin/sh' 'set -eu' \
    'test "$AGENT_ROUTER_KEY" = "$BAO_TEST_ROUTER_KEY"' \
    'test "$VIKUNJA_API_TOKEN" = "$BAO_TEST_VIKUNJA_TOKEN"' \
    'test "$ZAMMAD_HTTP_TOKEN" = "$BAO_TEST_ZAMMAD_TOKEN"' \
    'test -z "${SANDBOX_ROLE_ID:-}"' \
    'test -z "${SANDBOX_WRAPPED_SECRET_ID:-}"' \
    'printf "%s" "$ZCODE_MCP_CONFIG" | jq -e ".mcp.servers.vikunja.command and .mcp.servers.zammad.command" >/dev/null' \
    >"$child"
  chmod 700 "$child"
  sed \
    -e "s#@AGENT_ENTRYPOINT@#${child}#" \
    -e "s#/dev/shm/agent-openbao#${auth_dir}#g" \
    -e "s#/etc/openbao-agent/templates#${worktree}/templates/bao-agent#g" \
    "$worktree/templates/bao-agent/read.hcl" >"$config"

  BAO_ADDR="$address" AGENT_TOOL=zcode \
    AGENT_SANDBOX_ROUTER_KEY_FIELD=router_key \
    AGENT_MCP_VIKUNJA_COMMAND=/bin/vikunja-mcp \
    AGENT_MCP_ZAMMAD_COMMAND=/bin/sandbox-zammad-mcp AGENT_MCP_ZAMMAD_ARGS='[]' \
    BAO_TEST_ROUTER_KEY=router-test-key \
    BAO_TEST_VIKUNJA_TOKEN=vikunja-test-token \
    BAO_TEST_ZAMMAD_TOKEN=zammad-test-token \
    "$BAO_BIN" agent -config="$config" >/dev/null 2>&1
  [ ! -e "$auth_dir/wrapped-secret-id" ]
}
