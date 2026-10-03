# The `agent-dispatch` host dispatcher (wrapped by writeShellApplication).
#
# Runs on the sandbox Docker host. A job is one disposable container plus one
# named Docker volume, `agent-job-<id>`, mounted at /home/agent/work as its
# workspace. Every verb prints one JSON object on stdout.
#
#   start [--interactive] <tool> <owner/repo> <prompt>
#   continue <job-id> <message>
#   status <job-id>
#   cancel <job-id>
#   refresh
#
# Each start/continue logs in to OpenBao at BAO_ADDR with the AppRole in
# OPENBAO_APPROLE_OPEN_LLM_ROLE_ID / OPENBAO_APPROLE_OPEN_LLM_SECRET_ID, reads
# secret/apps/open-llm, and mints a GitHub token for the job's repo from
# github-agents/token. The token must cover exactly that one repo, or the job
# fails closed. The login token owns the lease behind the GitHub token, so a
# waiter renews it every half TTL while the container runs and revokes it
# when the run ends, which also ends the GitHub token. The run ends by the
# token's max TTL, and a failed renewal fails the run.
#
# The container receives the GitHub token, the tool's model key and the
# prompt as files copied in with `docker cp` between create and start. It
# never receives an OpenBao address, AppRole material, a host path or the
# Docker socket.

export LC_ALL=C
umask 077

IMAGE="${AGENT_IMAGE:-ghcr.io/dryvist/nix-agent-sandbox/agent:latest}"
STATE_DIR="${AGENT_DISPATCH_STATE_DIR:-/var/lib/agent-dispatch}"
BUCKET=secret/data/apps/open-llm
GITHUB_API=https://api.github.com
WEB_PORT=8080 # in-container port of an interactive web session
MAX_TEXT=16384
telemetry_config=${AGENT_DISPATCH_TELEMETRY_CONFIG:-/etc/agent-dispatch/telemetry.json}
if [ -z "${AGENT_DISPATCH_OTLP_METRICS_ENDPOINT:-}" ] && [ -f "$telemetry_config" ]; then
  AGENT_DISPATCH_OTLP_METRICS_ENDPOINT=$(jq -er '.endpoint | select(type == "string" and length > 0)' "$telemetry_config") || {
    echo 'agent-dispatch: invalid telemetry configuration' >&2
    AGENT_DISPATCH_OTLP_METRICS_ENDPOINT=''
  }
  export AGENT_DISPATCH_OTLP_METRICS_ENDPOINT
fi

usage() {
  cat >&2 <<'EOF'
usage:
  agent-dispatch start [--interactive] <tool> <owner/repo> <prompt>
  agent-dispatch continue <job-id> <message>
  agent-dispatch status <job-id>
  agent-dispatch cancel <job-id>
  agent-dispatch refresh

tools: zcode, opencode, cursor-agent (--interactive: zcode, opencode)
EOF
  exit 64
}

refuse() {
  echo "agent-dispatch: $1" >&2
  exit 64
}

# --- Argument validation (the only validator; dispatch-ssh relies on it) ---
valid_tool() {
  case "$1" in
    zcode | opencode | cursor-agent) ;;
    *) return 1 ;;
  esac
}

web_tool() {
  case "$1" in
    zcode | opencode) ;;
    *) return 1 ;;
  esac
}

# GitHub owner: alphanumerics and inner hyphens. Repo: [A-Za-z0-9._-], never
# "." or "..".
valid_repo() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$ ]] &&
    [ "${1#*/}" != . ] && [ "${1#*/}" != .. ]
}

valid_job() {
  [[ $1 =~ ^j-[0-9a-f]{16}$ ]]
}

# Prompt or message: non-empty, bounded, no ASCII control characters other
# than tab and newline. The text is data; nothing ever evaluates it.
valid_text() {
  local control=$'[\001-\010\013-\037\177]'
  [ -n "$1" ] && [ "${#1}" -le "$MAX_TEXT" ] && [[ $1 != *$control* ]]
}

rand_hex() {
  od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

# --- OpenBao and HTTP. Tokens travel in header files and bodies on file
# descriptors, never on a command line. ---
bao_login() {
  curl -sS --fail-with-body --max-time 60 -X POST \
    --data-binary @<(jq -n '{role_id: env.OPENBAO_APPROLE_OPEN_LLM_ROLE_ID,
      secret_id: env.OPENBAO_APPROLE_OPEN_LLM_SECRET_ID}') \
    "${BAO_ADDR:?}/v1/auth/approle/login"
}

# bao_req <method> <path> <token> [json-body]
bao_req() {
  if [ $# -ge 4 ]; then
    curl -sS --fail-with-body --max-time 60 -X "$1" \
      -H @<(printf 'X-Vault-Token: %s\n' "$3") \
      --data-binary @<(printf '%s' "$4") "${BAO_ADDR:?}/v1/$2"
  else
    curl -sS --fail-with-body --max-time 60 -X "$1" \
      -H @<(printf 'X-Vault-Token: %s\n' "$3") "${BAO_ADDR:?}/v1/$2"
  fi
}

bao_revoke() {
  bao_req POST auth/token/revoke-self "$1" >/dev/null 2>&1 || true
}

# field <name>: one value from the caller's $bucket (a KV v2 read).
field() {
  jq -r --arg k "$1" '.data.data[$k] // empty' <<<"$bucket"
}

# The token must list exactly the job's repo: the mint request names only the
# repo, so this is where the owner is checked.
scope_ok() {
  local resp
  resp=$(curl -sS --fail-with-body --max-time 30 \
    -H @<(printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\n' "$1") \
    "$GITHUB_API/installation/repositories") || return 1
  jq -e --arg r "$2" '.total_count == 1 and
    (.repositories[0].full_name | ascii_downcase) == ($r | ascii_downcase)' \
    <<<"$resp" >/dev/null
}

# --- Job state: $STATE_DIR/<id>/{job.json,pr_url,runs/<n>/...} ---
latest_run() {
  local r n=0
  for r in "$STATE_DIR/$1"/runs/*; do
    r=${r##*/}
    if [[ $r =~ ^[0-9]+$ ]] && [ "$r" -gt "$n" ]; then n=$r; fi
  done
  echo "$n"
}

job_get() {
  jq -r "$2" "$STATE_DIR/$1/job.json"
}

job_json() {
  local dir="$STATE_DIR/$1" run rdir started ended
  run=$(latest_run "$1")
  rdir="$dir/runs/$run"
  started=$(cat "$rdir/started" 2>/dev/null || date +%s)
  ended=$(cat "$rdir/ended" 2>/dev/null || date +%s)
  jq -c --arg state "$(cat "$rdir/state" 2>/dev/null || echo starting)" \
    --arg reason "$(cat "$rdir/reason" 2>/dev/null || true)" \
    --arg pr "$(cat "$dir/pr_url" 2>/dev/null || true)" \
    --argjson tokens "$(cat "$rdir/tokens" 2>/dev/null || echo null)" \
    --argjson runs "$run" --argjson duration "$((ended - started))" \
    '. + {state: $state, reason: $reason, pr: $pr, runs: $runs, duration: $duration, tokens: $tokens}' \
    "$dir/job.json"
}

# The fixed-format result. Every value was validated or generated here; no
# model output reaches it.
result_lines() {
  local dir="$STATE_DIR/$1" rdir="$STATE_DIR/$1/runs/$2" started ended
  started=$(cat "$rdir/started")
  ended=$(cat "$rdir/ended")
  printf 'job: %s\ntool: %s\nrepo: %s\nstate: %s\npr: %s\nduration: %ss\n' \
    "$1" "$(job_get "$1" .tool)" "$(job_get "$1" .repo)" "$(cat "$rdir/state")" \
    "$(cat "$dir/pr_url" 2>/dev/null || echo none)" "$((ended - started))"
  printf 'tokens: %s\n' "$(cat "$rdir/tokens" 2>/dev/null | sed 's/^null$/unknown/' || echo unknown)"
}

# One event gauge per run, using its immutable completion time on retries.
# Status is read-only; refresh retries an unsuccessful delivery of this payload.
emit_metrics() (
  local id=$1 run=$2 rdir="$STATE_DIR/$1/runs/$2" response
  [ ! -f "$rdir/metrics.sent" ] || return 0
  [ -n "${AGENT_DISPATCH_OTLP_METRICS_ENDPOINT:-}" ] || return 0
  mkdir "$rdir/metrics.lock" 2>/dev/null || return 0
  trap 'rmdir "$rdir/metrics.lock"' EXIT
  if [ ! -f "$rdir/metrics.json" ]; then
    jq -n --slurpfile job "$STATE_DIR/$id/job.json" \
      --arg run "$run" --arg outcome "$(cat "$rdir/state")" \
      --arg time "$(cat "$rdir/ended")000000000" \
      --argjson duration "$(($(cat "$rdir/ended") - $(cat "$rdir/started")))" \
      --argjson tokens "$(cat "$rdir/tokens" 2>/dev/null || echo null)" '
      def attr($k; $v): {key:$k,value:{stringValue:$v}};
      [attr("job";$job[0].job),attr("run";$run),attr("tool";$job[0].tool),
       attr("repo";$job[0].repo),attr("outcome";$outcome)] as $attrs |
      def metric($name; $value; $extra): {name:$name,gauge:{dataPoints:[{
        attributes:($attrs + $extra),timeUnixNano:$time,asDouble:$value}]}};
      {resourceMetrics:[{resource:{attributes:[attr("service.name";"agent-dispatch")]},
        scopeMetrics:[{scope:{name:"agent-dispatch"},metrics:[
          metric("agent_dispatch_runs";1;[]),
          metric("agent_dispatch_duration_seconds";$duration;[]),
          (if $tokens != null then metric("agent_dispatch_tokens";$tokens;
            [attr("token_type";"total")]) else empty end)]}]}]}' >"$rdir/metrics.json"
  fi
  response=$(curl -sS --fail-with-body --max-time 30 -X POST \
    -H @<(printf 'Content-Type: application/json\n';
      if [ -n "${AGENT_DISPATCH_OTLP_HEADERS_FILE:-}" ]; then cat "$AGENT_DISPATCH_OTLP_HEADERS_FILE"; fi) \
    --data-binary @"$rdir/metrics.json" "$AGENT_DISPATCH_OTLP_METRICS_ENDPOINT") || return 1
  [ -n "$response" ] || response='{}'
  jq -e '(.partialSuccess.rejectedDataPoints // "0" | tonumber) == 0' \
    <<<"$response" >/dev/null || return 1
  touch "$rdir/metrics.sent"
)

read_tokens() {
  local raw
  raw=$(docker cp "$1:/home/agent/work/.agent-usage-$2.json" - 2>/dev/null |
    tar -xOf - 2>/dev/null | head -c 1048576) || true
  jq -ser 'select(length == 1) | .[0] | select(type == "object") | select((.turnResponses // [] | length) <= 1) |
    .usage.totalTokens | select(type == "number" and . >= 0 and . <= 9007199254740991 and . == floor)' \
    <<<"$raw" 2>/dev/null || echo null
}

notify() {
  local id=$1 run=$2 lines title pr login tok bucket url token rc=0
  local topic="${AGENT_DISPATCH_NTFY_TOPIC:-ai-jobs}"
  lines=$(result_lines "$id" "$run")
  title="ai-job $id $(cat "$STATE_DIR/$id/runs/$run/state")"
  pr=$(cat "$STATE_DIR/$id/pr_url" 2>/dev/null || true)

  login=$(bao_login) || return 1
  tok=$(jq -r '.auth.client_token // empty' <<<"$login")
  [ -n "$tok" ] || return 1
  bucket=$(bao_req GET "$BUCKET" "$tok") || {
    bao_revoke "$tok"
    return 1
  }
  bao_revoke "$tok"

  url=$(field VIKUNJA_URL)
  token=$(field VIKUNJA_AI_JOBS_TOKEN)
  if [[ ${AGENT_DISPATCH_VIKUNJA_PROJECT:-} =~ ^[0-9]+$ ]] && [ -n "$url" ] && [ -n "$token" ]; then
    curl -sS --fail-with-body --max-time 30 -o /dev/null -X PUT \
      -H @<(printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$token") \
      --data-binary @<(jq -n --arg t "$title" --arg d "<p>${lines//$'\n'/<br>}</p>" \
        '{title: $t, description: $d}') \
      "$url/projects/$AGENT_DISPATCH_VIKUNJA_PROJECT/tasks" || rc=1
  else
    echo "agent-dispatch: $id: Vikunja result skipped: project, URL or token missing" >&2
    rc=1
  fi

  url=$(field NTFY_URL)
  token=$(field NTFY_AI_JOBS_TOKEN)
  if [[ $topic =~ ^[A-Za-z0-9_-]{1,64}$ ]] && [ -n "$url" ] && [ -n "$token" ]; then
    curl -sS --fail-with-body --max-time 30 -o /dev/null -X POST \
      -H @<(
        printf 'Authorization: Bearer %s\nTitle: %s\n' "$token" "$title"
        if [ -n "$pr" ]; then printf 'Click: %s\n' "$pr"; fi
      ) \
      --data-binary @<(printf '%s\n' "$lines") "$url/$topic" || rc=1
  else
    echo "agent-dispatch: $id: ntfy result skipped: topic, URL or token missing" >&2
    rc=1
  fi
  return "$rc"
}

# The PR URL the entrypoint wrote after the tool exited, accepted only when
# it points at the job's repo.
read_pr_url() {
  local url prefix="https://github.com/$2/pull/" n
  url=$(docker cp "$1:/home/agent/work/.agent-pr-url" - 2>/dev/null |
    tar -xOf - 2>/dev/null | head -c 300 | head -n 1) || true
  [[ ${url,,} == "${prefix,,}"* ]] || return 0
  n=${url:${#prefix}}
  if [[ $n =~ ^[0-9]+$ ]]; then printf '%s\n' "$url"; fi
}

# finalize <id> <run>: settle a run's terminal state once, remove its
# container (the volume stays for `continue`), and post the result.
finalize() {
  local id=$1 run=$2 rdir="$STATE_DIR/$1/runs/$2" state cid code pr
  mkdir "$rdir/final" 2>/dev/null || return 0
  code=$(cat "$rdir/exit" 2>/dev/null || true)
  if [ -f "$rdir/reason" ]; then
    state=failed
  elif [ -e "$rdir/cancel" ]; then
    state=cancelled
  elif [ -e "$rdir/timeout" ]; then
    state=timeout
  elif [ "$code" = 0 ]; then
    state=succeeded
  else
    state=failed
    echo "exit ${code:-unknown}" >"$rdir/reason"
  fi
  cid=$(cat "$rdir/cid" 2>/dev/null || true)
  if [ -n "$cid" ]; then
    pr=$(read_pr_url "$cid" "$(job_get "$id" .repo)")
    if [ -n "$pr" ]; then echo "$pr" >"$STATE_DIR/$id/pr_url"; fi
    if [ "$(job_get "$id" .tool)" = zcode ]; then
      read_tokens "$cid" "$run" >"$rdir/tokens"
    fi
    docker rm -f "$cid" >/dev/null 2>&1 || true
  fi
  date +%s >"$rdir/ended"
  echo "$state" >"$rdir/state"
  emit_metrics "$id" "$run" || echo "agent-dispatch: $id: metrics delivery incomplete" >&2
  notify "$id" "$run" || echo "agent-dispatch: $id: result notification incomplete" >&2
}

# abort <id> <run> <reason> [openbao-token]: fail the run closed and print
# the job JSON.
abort() {
  echo "$3" >"$STATE_DIR/$1/runs/$2/reason"
  if [ -n "${4:-}" ]; then bao_revoke "$4"; fi
  finalize "$1" "$2"
  job_json "$1"
}

# container_args <id> <run> <tool> <repo> <interactive> <continue>: the
# `docker create` arguments, into $args. Only non-secret values appear here.
container_args() {
  local proxy="${AGENT_PROXY_URL:-http://proxy:3128}" host router
  args=(
    --name "agent-$1-$2"
    --label "agent-dispatch.job=$1"
    --network "${AGENT_NETWORK:-agents}"
    -e "HTTP_PROXY=$proxy"
    -e "HTTPS_PROXY=$proxy"
    -e "http_proxy=$proxy"
    -e "https_proxy=$proxy"
    -e "AGENT_TOOL=$3"
    -e "AGENT_PROFILE=$3"
    -e "AGENT_REPO=$4"
    -e "AGENT_RUN_ID=$1"
    -e "AGENT_DISPATCH_RUN=$2"
    -e AGENT_PR_DRAFT=1
    -v "agent-job-$1:/home/agent/work"
    --memory "${AGENT_MEMORY:-$AGENT_MEMORY_DEFAULT}"
    --cpus "${AGENT_CPUS:-$AGENT_CPUS_DEFAULT}"
    --pids-limit "${AGENT_PIDS_LIMIT:-$AGENT_PIDS_LIMIT_DEFAULT}"
    --security-opt no-new-privileges
    --cap-drop ALL
  )
  if [ "$6" = 1 ]; then args+=(-e AGENT_CONTINUE=1); fi
  if [ "$5" = 1 ]; then
    host="$1.$AGENT_DISPATCH_INGRESS_DOMAIN"
    router="agent-$1"
    args+=(
      -e AGENT_INTERACTIVE=1
      -e "AGENT_PORT=$WEB_PORT"
      --label traefik.enable=true
      --label "traefik.docker.network=${AGENT_DISPATCH_INGRESS_NETWORK:-agents-ingress}"
      --label "traefik.http.routers.$router.rule=Host(\`$host\`)"
      --label "traefik.http.services.$router.loadbalancer.server.port=$WEB_PORT"
    )
    if [ -n "${AGENT_DISPATCH_INGRESS_MIDDLEWARES:-}" ]; then
      args+=(--label "traefik.http.routers.$router.middlewares=$AGENT_DISPATCH_INGRESS_MIDDLEWARES")
    fi
  fi
  args+=("$IMAGE")
}

# deliver <cid> <prompt>: the run's secrets (NAME=value lines) and prompt, as
# files owned by the container's uid 1000, streamed in with `docker cp`.
# Uses the caller's $names, $bucket, $gh and $web.
deliver() {
  local tmp name value rc=0
  tmp=$(mktemp -d)
  {
    printf 'GH_TOKEN=%s\nGITHUB_TOKEN=%s\n' "$gh" "$gh"
    for name in "${names[@]}"; do
      value=$(field "$name")
      [[ $value != *$'\n'* ]] || rc=1
      printf '%s=%s\n' "$name" "$value"
    done
    if [ -n "$web" ]; then printf 'AGENT_WEB_TOKEN=%s\n' "$web"; fi
  } >"$tmp/.agent-env"
  printf '%s' "$2" >"$tmp/.agent-prompt"
  if [ "$rc" = 0 ]; then
    tar --numeric-owner --owner=1000 --group=1000 -C "$tmp" -cf - .agent-env .agent-prompt |
      docker cp - "$1:/home/agent/" >/dev/null || rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

# run_job <id> <run> <prompt>: log in, mint, create, deliver, start, and hand
# the run to a detached waiter. Prints the job JSON; fails closed.
run_job() {
  local id=$1 run=$2 prompt=$3 rdir="$STATE_DIR/$1/runs/$2"
  local tool repo interactive cont=0 login tok lease bucket iid mint gh="" web="" budget cid name
  local -a names args
  tool=$(job_get "$id" .tool)
  repo=$(job_get "$id" .repo)
  interactive=$(job_get "$id" 'if .interactive then 1 else 0 end')
  if [ "$run" != 1 ]; then cont=1; fi
  date +%s >"$rdir/started"
  echo starting >"$rdir/state"

  login=$(bao_login) || {
    abort "$id" "$run" "openbao login failed"
    return 1
  }
  tok=$(jq -r '.auth.client_token // empty' <<<"$login")
  lease=$(jq -r '.auth.lease_duration // 0' <<<"$login")
  [ -n "$tok" ] || {
    abort "$id" "$run" "openbao login returned no token"
    return 1
  }
  bucket=$(bao_req GET "$BUCKET" "$tok") || {
    abort "$id" "$run" "bucket read failed" "$tok"
    return 1
  }
  iid=$(field GITHUB_AGENTS_INSTALLATION_ID)
  [ -n "$iid" ] || {
    abort "$id" "$run" "bucket has no GITHUB_AGENTS_INSTALLATION_ID" "$tok"
    return 1
  }
  mapfile -t names < <(jq -r --arg t "$tool" '.[$t].env[]?' <<<"$AGENT_TASK_PROFILES")
  [ "${#names[@]}" -gt 0 ] || {
    abort "$id" "$run" "no task profile for $tool" "$tok"
    return 1
  }
  for name in "${names[@]}"; do
    [ -n "$(field "$name")" ] || {
      abort "$id" "$run" "bucket has no $name" "$tok"
      return 1
    }
  done

  # One repo, contents + pull requests only (no workflow edits). The
  # installation id and repo travel as strings, the form the policy matches.
  mint=$(bao_req POST github-agents/token "$tok" "$(jq -cn --arg i "$iid" --arg r "${repo#*/}" \
    '{installation_id: $i, repositories: $r,
      permissions: {contents: "write", pull_requests: "write"}}')") || {
    abort "$id" "$run" "github token mint refused for $repo" "$tok"
    return 1
  }
  gh=$(jq -r '.data.token // empty' <<<"$mint")
  if [ -z "$gh" ] || ! scope_ok "$gh" "$repo"; then
    abort "$id" "$run" "github token is not scoped to exactly $repo" "$tok"
    return 1
  fi

  budget="${AGENT_TIMEOUT:-$AGENT_TIMEOUT_DEFAULT}"
  echo "$budget" >"$rdir/budget"
  echo "$lease" >"$rdir/ttl"
  container_args "$id" "$run" "$tool" "$repo" "$interactive" "$cont"
  cid=$(docker create "${args[@]}") || {
    abort "$id" "$run" "container create failed" "$tok"
    return 1
  }
  echo "$cid" >"$rdir/cid"
  if [ "$interactive" = 1 ]; then
    web=$(rand_hex 24)
    docker network connect "${AGENT_DISPATCH_INGRESS_NETWORK:-agents-ingress}" "$cid" >/dev/null || {
      abort "$id" "$run" "ingress network connect failed" "$tok"
      return 1
    }
  fi
  deliver "$cid" "$prompt" || {
    abort "$id" "$run" "credential delivery failed" "$tok"
    return 1
  }
  docker start "$cid" >/dev/null || {
    abort "$id" "$run" "container start failed" "$tok"
    return 1
  }
  echo running >"$rdir/state"

  # The waiter holds the login token (stdin, never argv or disk) until the
  # run ends, then revokes it and finalizes.
  printf '%s' "$tok" | setsid -f "$0" __wait "$id" "$run" >>"$STATE_DIR/$id/dispatch.log" 2>&1
  if [ -n "$web" ]; then
    # Shown once, to this caller; stored nowhere on the host.
    job_json "$id" | AGENT_WEB_TOKEN=$web jq -c '. + {web_token: env.AGENT_WEB_TOKEN}'
  else
    job_json "$id"
  fi
}

# wait_run <id> <run>: wait for the container in slices of half the login
# token's TTL and renew the token between slices. The run ends when the
# container exits. It ends as a timeout when AGENT_TIMEOUT passes or when the
# token cannot be renewed past its max TTL. A failed renewal kills the
# container and fails the run. The token is revoked on every path.
wait_run() {
  local id=$1 run=$2 rdir="$STATE_DIR/$1/runs/$2" tok="" cid code rc ttl step
  local now end deadline expiry slice renewed lease
  IFS= read -r tok || true
  cid=$(cat "$rdir/cid")
  ttl=$(cat "$rdir/ttl")
  now=$(date +%s)
  deadline=$((now + $(cat "$rdir/budget")))
  expiry=$deadline
  if [ "$ttl" -gt 0 ]; then expiry=$((now + ttl)); fi
  step=$((ttl / 2))
  if [ "$step" -lt 1 ]; then step=1; fi
  while :; do
    now=$(date +%s)
    end=$((deadline < expiry ? deadline : expiry))
    if [ "$now" -ge "$end" ]; then
      : >"$rdir/timeout"
      docker kill "$cid" >/dev/null 2>&1 || true
      break
    fi
    slice=$((end - now))
    if [ "$ttl" -gt 0 ] && [ "$slice" -gt "$step" ]; then slice=$step; fi
    rc=0
    code=$(timeout "$slice" docker wait "$cid") || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "$code" >"$rdir/exit"
      break
    fi
    # Anything but a slice running out is a docker error: finalize fails it.
    [ "$rc" -eq 124 ] || break
    # Renew only a renewable token with time left before this run's end.
    if [ "$ttl" -le 0 ] || [ "$(date +%s)" -ge "$end" ]; then continue; fi
    renewed=$(bao_req POST auth/token/renew-self "$tok" '{}') || renewed=""
    lease=$(jq -r '.auth.lease_duration // 0' <<<"$renewed" 2>/dev/null) || lease=0
    if [ "${lease:-0}" -le 0 ]; then
      echo "openbao token renewal failed" >"$rdir/reason"
      docker kill "$cid" >/dev/null 2>&1 || true
      break
    fi
    # At the max TTL the renewal comes back short; the run then ends with
    # the token.
    expiry=$(($(date +%s) + lease))
  done
  if [ -n "$tok" ]; then bao_revoke "$tok"; fi
  finalize "$id" "$run"
}

job_exists() {
  valid_job "$1" || refuse "invalid job id"
  [ -f "$STATE_DIR/$1/job.json" ] || {
    jq -cn --arg job "$1" '{job: $job, error: "no such job"}'
    exit 1
  }
}

cmd_start() {
  local interactive=0 tool repo prompt id dir ingress=""
  if [ "${1:-}" = --interactive ]; then
    interactive=1
    shift
  fi
  [ $# -eq 3 ] || usage
  tool=$1 repo=$2 prompt=$3
  valid_tool "$tool" || refuse "unknown tool"
  valid_repo "$repo" || refuse "invalid owner/repo"
  valid_text "$prompt" || refuse "invalid prompt"
  if [ "$interactive" = 1 ]; then
    web_tool "$tool" || refuse "tool has no web session"
    [ -n "${AGENT_DISPATCH_INGRESS_DOMAIN:-}" ] || refuse "--interactive needs AGENT_DISPATCH_INGRESS_DOMAIN"
  fi
  id="j-$(rand_hex 8)"
  dir="$STATE_DIR/$id"
  mkdir -p "$STATE_DIR"
  mkdir "$dir"
  mkdir -p "$dir/runs/1"
  if [ "$interactive" = 1 ]; then ingress="https://$id.$AGENT_DISPATCH_INGRESS_DOMAIN"; fi
  jq -n --arg job "$id" --arg tool "$tool" --arg repo "$repo" \
    --argjson i "$interactive" --arg ingress "$ingress" \
    '{job: $job, tool: $tool, repo: $repo, interactive: ($i == 1), ingress: $ingress}' \
    >"$dir/job.json"
  run_job "$id" 1 "$prompt"
}

cmd_continue() {
  local id last next
  [ $# -eq 2 ] || usage
  id=$1
  valid_job "$id" || refuse "invalid job id"
  valid_text "$2" || refuse "invalid message"
  job_exists "$id"
  if [ "$(job_get "$id" .interactive)" = true ]; then
    refuse "an interactive job continues in its web session"
  fi
  last=$(latest_run "$id")
  [ -d "$STATE_DIR/$id/runs/$last/final" ] || {
    job_json "$id"
    echo "agent-dispatch: job is still running" >&2
    exit 1
  }
  next=$((last + 1))
  mkdir "$STATE_DIR/$id/runs/$next" 2>/dev/null || {
    echo "agent-dispatch: job is busy" >&2
    exit 1
  }
  run_job "$id" "$next" "$2"
}

cmd_cancel() {
  local id=$1 rdir cid
  job_exists "$id"
  rdir="$STATE_DIR/$id/runs/$(latest_run "$id")"
  [ ! -d "$rdir/final" ] || {
    job_json "$id"
    echo "agent-dispatch: job is not running" >&2
    exit 1
  }
  : >"$rdir/cancel"
  cid=$(cat "$rdir/cid" 2>/dev/null || true)
  if [ -n "$cid" ]; then docker kill "$cid" >/dev/null 2>&1 || true; fi
  job_json "$id" | jq -c '.state = "cancelling"'
}

# refresh: settle runs whose waiter is gone, then prune finished jobs older
# than AGENT_DISPATCH_RETENTION seconds (container, volume and state).
cmd_refresh() {
  local now dir id rdir cid status ended pending unsent keep="${AGENT_DISPATCH_RETENTION:-86400}"
  local -a settled=() pruned=()
  now=$(date +%s)
  for dir in "$STATE_DIR"/j-*; do
    id=${dir##*/}
    if ! valid_job "$id" || [ ! -f "$dir/job.json" ]; then continue; fi
    rdir="$dir/runs/$(latest_run "$id")"
    if [ ! -d "$rdir/final" ]; then
      cid=$(cat "$rdir/cid" 2>/dev/null || true)
      if [ -z "$cid" ]; then
        # A launch that never created a container and is long past due.
        [ $((now - $(cat "$rdir/started" 2>/dev/null || echo "$now"))) -ge 600 ] || continue
        echo "launch interrupted" >"$rdir/reason"
      else
        status=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo gone)
        case "$status" in
          created | running | restarting | paused) continue ;;
        esac
        docker inspect -f '{{.State.ExitCode}}' "$cid" >"$rdir/exit" 2>/dev/null || rm -f "$rdir/exit"
      fi
      finalize "$id" "${rdir##*/}"
      settled+=("$id")
    else
      unsent=0
      for pending in "$dir"/runs/*; do
        if [ -f "$pending/ended" ]; then
          emit_metrics "$id" "${pending##*/}" || echo "agent-dispatch: $id: metrics delivery incomplete" >&2
          if [ -n "${AGENT_DISPATCH_OTLP_METRICS_ENDPOINT:-}" ] && [ ! -f "$pending/metrics.sent" ]; then unsent=1; fi
        fi
      done
      [ "$unsent" = 0 ] || continue
      ended=$(cat "$rdir/ended" 2>/dev/null || echo "$now")
      if [ $((now - ended)) -ge "$keep" ]; then
        docker volume rm -f "agent-job-$id" >/dev/null 2>&1 || true
        rm -rf "$dir"
        pruned+=("$id")
      fi
    fi
  done
  jq -cn --arg s "${settled[*]}" --arg p "${pruned[*]}" \
    '{settled: ($s | split(" ") | map(select(. != ""))),
      pruned: ($p | split(" ") | map(select(. != "")))}'
}

cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in
  start) cmd_start "$@" ;;
  continue) cmd_continue "$@" ;;
  status)
    [ $# -eq 1 ] || usage
    job_exists "$1"
    job_json "$1"
    ;;
  cancel)
    [ $# -eq 1 ] || usage
    cmd_cancel "$1"
    ;;
  refresh)
    [ $# -eq 0 ] || usage
    cmd_refresh
    ;;
  __wait)
    # Internal: the detached waiter run_job starts. Not reachable over SSH.
    if [ $# -ne 2 ] || ! valid_job "$1" || [[ ! $2 =~ ^[0-9]+$ ]]; then usage; fi
    wait_run "$1" "$2"
    ;;
  *) usage ;;
esac
