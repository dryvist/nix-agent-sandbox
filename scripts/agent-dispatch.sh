# The `agent-dispatch` host dispatcher (wrapped by writeShellApplication).
#
# Runs on the sandbox Docker host. A job is one disposable container plus one
# named Docker volume, `agent-job-<id>`, mounted at /home/agent/work as its
# workspace. Every verb prints one JSON object on stdout.
#
#   start <tool> <owner/repo> <prompt>
#   start --tty <tool> <owner/repo>
#   fix <tool> <owner/repo> <branch> <expected-sha> <prompt>
#   continue <job-id> <message>
#   status <job-id>
#   cancel <job-id>
#   refresh
#   check
#
# Each job uses one service token to read its profile. Start jobs mint a
# repository write token; fix jobs use a read token for checks, then mint a
# write token on the host after the container exits.
#
# The container receives the GitHub token, the selected profile values and
# the prompt as files copied in with `docker cp` between create and start. It
# never receives service credentials, a host path or the Docker socket.
#
# `--tty` runs the same job attached to the caller's terminal: the container
# gets a TTY, and the dispatcher attaches to it after the waiter takes over.
# A tool whose profile sets ttyLogin signs in by hand inside the session and
# gets no router key. Only public repositories whose default branch requires
# a pull request are accepted.

export LC_ALL=C
set +x
umask 077

IMAGE="${AGENT_IMAGE:-ghcr.io/dryvist/nix-agent-sandbox/agent:latest}"
STATE_DIR="${AGENT_DISPATCH_STATE_DIR:-/var/lib/agent-dispatch}"
APPROLE_DIR="${AGENT_DISPATCH_APPROLE_DIR:-/etc/agent-dispatch/approle}"
BUCKET=secret/data/apps/open-llm
ZAI_BUCKET=secret/data/secrets-external/zai-coding
GITHUB_API=https://api.github.com
MAX_TEXT=16384
JOB_MANAGER=0
JOB_TOKEN_TTL=0
JOB_ENDED=0
JOB_REDACT_VALUES=()

usage() {
  cat >&2 <<'EOF'
usage:
  agent-dispatch start <tool> <owner/repo> <prompt>
  agent-dispatch fix <tool> <owner/repo> <branch> <expected-sha> <prompt>
  agent-dispatch start --tty <tool> <owner/repo>
  agent-dispatch continue <job-id> <message>
  agent-dispatch status <job-id>
  agent-dispatch cancel <job-id>
  agent-dispatch refresh
  agent-dispatch check

tools: zcode, opencode, opencode-local, opencode-zai, cursor-agent, qwen-code
fix-only tool: shell (runs the prompt as a bash command)
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
    zcode | opencode | opencode-local | opencode-zai | cursor-agent | qwen-code) ;;
    *) return 1 ;;
  esac
}

# GitHub owner: alphanumerics and inner hyphens. Repo: [A-Za-z0-9._-], never
# "." or "..".
valid_repo() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$ ]] &&
    [ "${1#*/}" != . ] && [ "${1#*/}" != .. ]
}

repo_scope_guard() {
  local owner_lc=${1%%/*} denied
  local -a denied_owners
  owner_lc=${owner_lc,,}
  case "$owner_lc" in
    dryvist | jacobpevans | jacobpevans-personal) ;;
    *) echo "repository owner refused"; return ;;
  esac
  if [[ ! ${AGENT_REPO_DENYLIST:-} =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}(,[A-Za-z0-9][A-Za-z0-9-]{0,38})*$ ]]; then
    echo "repository denylist is missing or invalid"
    return
  fi
  IFS=, read -r -a denied_owners <<<"$AGENT_REPO_DENYLIST"
  for denied in "${denied_owners[@]}"; do
    [ "$owner_lc" != "${denied,,}" ] || {
      echo "repository owner refused"
      return
    }
  done
}

valid_job() {
  [[ $1 =~ ^j-[0-9a-f]{16}$ ]]
}

valid_branch() {
  local part
  local -a parts
  [[ $1 =~ ^[A-Za-z0-9._/-]{1,200}$ ]] && [[ $1 != -* ]] && [[ $1 != /* ]] &&
    [[ $1 != */ ]] && [[ $1 != *.lock ]] && [[ $1 != *..* ]] && [[ $1 != *//* ]] || return 1
  IFS=/ read -r -a parts <<<"$1"
  for part in "${parts[@]}"; do
    [[ -n $part && $part != .* && $part != *..* && $part != *. && $part != *.lock ]] || return 1
  done
}

# Prompt or message: non-empty, bounded, no ASCII control characters other
# than tab and newline. The text is data; nothing ever evaluates it.
valid_text() {
  local control=$'[\001-\010\013-\037\177]'
  [ -n "$1" ] && [ "${#1}" -le "$MAX_TEXT" ] && [[ $1 != *$control* ]]
}

single_line() {
  [[ $1 != *$'\n'* && $1 != *$'\r'* ]]
}

rand_hex() {
  od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

# --- Service requests. Tokens travel in header files and bodies on file
# descriptors, never on a command line. ---
bao_login() {
  local role_file="$APPROLE_DIR/role_id" secret_file="$APPROLE_DIR/secret_id" role_id secret_id file
  for file in "$role_file" "$secret_file"; do
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
      echo "agent-dispatch: required credential file is missing or unreadable: $file" >&2
      return 64
    fi
  done
  role_id=$(<"$role_file")
  secret_id=$(<"$secret_file")
  if [ -z "$role_id" ] || [ -z "$secret_id" ]; then
    echo "agent-dispatch: required credential file is empty under $APPROLE_DIR" >&2
    return 64
  fi
  curl -sS --fail-with-body --max-time 60 -X POST \
    --data-binary @<(ROLE_ID="$role_id" SECRET_ID="$secret_id" \
      jq -n '{role_id: env.ROLE_ID, secret_id: env.SECRET_ID}') \
    "${BAO_ADDR:?}/v1/auth/approle/login"
}

# service_login: one AppRole login into the caller's $login. On refusal it
# sets the caller's $reason to a one-line cause and returns 1.
service_login() {
  local rc=0
  login=$(bao_login) || rc=$?
  if [ "$rc" -eq 64 ]; then
    reason="credential files are missing or unreadable"
  elif [ "$rc" -ne 0 ]; then
    reason=$(jq -r '.errors[0] // empty' <<<"$login" 2>/dev/null || true)
    reason=${reason//$'\n'/ }
    reason=${reason//$'\r'/ }
    reason=${reason:0:300}
    [ -n "$reason" ] || reason="request failed"
  elif [ -z "$(jq -r '.auth.client_token // empty' <<<"$login")" ]; then
    reason="login returned no token"
  else
    return 0
  fi
  return 1
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

bao_wrap_req() {
  curl -sS --fail-with-body --max-time 60 -X POST \
    -H @<(printf 'X-Vault-Token: %s\n' "$2") \
    -H 'X-Vault-Wrap-TTL: 15m' "${BAO_ADDR:?}/v1/auth/approle/role/$1/secret-id"
}

bao_revoke_wrap() {
  bao_req POST sys/wrapping/revoke "$1" >/dev/null 2>&1 || true
}

# field <name>: one value from the caller's $bucket (a KV v2 read).
field() {
  jq -r --arg k "$1" '.data.data[$k] // empty' <<<"$bucket"
}

external_field() {
  jq -r --arg k "$1" '.data.data[$k] // empty' <<<"$external_bucket"
}

credential_value() {
  if [ "$1" = ZAI_SUBSCRIPTION_KEY ]; then external_field "$1"; else field "$1"; fi
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

gh_get() {
  curl -sS --fail-with-body --max-time 30 \
    -H @<(printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\n' "$1") \
    "$GITHUB_API/$2"
}

# repo_guard <token> <repo>: prints why the repo is refused, or nothing. Only
# a public repository whose default branch has an active ruleset requiring a
# pull request runs here, so a job can reach the default branch only through
# a reviewed PR. Classic branch protection is not readable with the job
# token and does not count.
repo_guard() {
  local resp="" branch rules=""
  resp=$(gh_get "$1" "repos/$2") || true
  if ! jq -e '.private == false and .visibility == "public"' <<<"$resp" >/dev/null 2>&1; then
    echo "private or unknown repository refused: $2"
    return
  fi
  branch=$(jq -r '.default_branch // empty | @uri' <<<"$resp")
  rules=$(gh_get "$1" "repos/$2/rules/branches/$branch") || true
  if ! jq -e 'any(.[]; .type == "pull_request")' <<<"$rules" >/dev/null 2>&1; then
    echo "default branch of $2 does not require a pull request"
  fi
}

# A refused repository's token is revoked at once.
gh_revoke() {
  curl -sS --max-time 30 -o /dev/null -X DELETE \
    -H @<(printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\n' "$1") \
    "$GITHUB_API/installation/token" >/dev/null 2>&1 || true
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
  local dir="$STATE_DIR/$1" run rdir started ended commit
  run=$(latest_run "$1")
  rdir="$dir/runs/$run"
  started=$(cat "$rdir/started" 2>/dev/null || date +%s)
  ended=$(cat "$rdir/ended" 2>/dev/null || date +%s)
  commit=$(cat "$dir/commit" 2>/dev/null || true)
  jq -c --arg state "$(cat "$rdir/state" 2>/dev/null || echo starting)" \
    --arg reason "$(cat "$rdir/reason" 2>/dev/null || true)" \
    --arg pr "$(cat "$dir/pr_url" 2>/dev/null || true)" \
    --arg commit "$commit" \
    --argjson runs "$run" --argjson duration "$((ended - started))" \
    '. + {state: $state, reason: $reason, pr: $pr, runs: $runs, duration: $duration, commit: $commit}' \
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
}

post_ntfy() {
  local url=$1 topic=$2 token=$3 title=$4 body=$5 pr=${6:-}
  curl -sS --fail-with-body --max-time 30 -o /dev/null -X POST \
    -H @<(printf 'Authorization: Bearer %s\nTitle: %s\n' "$token" "$title"
      if [ -n "$pr" ]; then printf 'Click: %s\n' "$pr"; fi) \
    --data-binary @<(printf '%s\n' "$body") "$url/$topic"
}

notify_login_refused() {
  local reason=$1 url="${AGENT_DISPATCH_NTFY_ALERT_URL:-}" token="${AGENT_DISPATCH_NTFY_ALERT_TOKEN:-}"
  local topic="${AGENT_DISPATCH_NTFY_TOPIC:-ai-jobs}" body
  if [ -z "$url" ] || [ -z "$token" ] || [[ ! $topic =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
    echo "agent-dispatch: login refusal alert not configured" >&2
    return 1
  fi
  body=$(printf 'role: open-llm\nreason: %s' "$reason")
  post_ntfy "$url" "$topic" "$token" "agent-dispatch login refused" "$body"
}

notify() {
  local id=$1 run=$2 tok=$3 lines title pr bucket url token rc=0
  local topic="${AGENT_DISPATCH_NTFY_TOPIC:-ai-jobs}"
  lines=$(result_lines "$id" "$run")
  title="ai-job $id $(cat "$STATE_DIR/$id/runs/$run/state")"
  pr=$(cat "$STATE_DIR/$id/pr_url" 2>/dev/null || true)

  bucket=$(bao_req GET "$BUCKET" "$tok") || {
    return 1
  }

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
    post_ntfy "$url" "$topic" "$token" "$title" "$lines" "$pr" || rc=1
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

# gh_status_get <token> <path>: set GH_HTTP_STATUS and GH_HTTP_BODY.
gh_status_get() {
  local response
  response=$(curl -sS --max-time 30 -w $'\n%{http_code}' \
    -H @<(printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\n' "$1") \
    "$GITHUB_API/$2") || return 1
  GH_HTTP_STATUS=${response##*$'\n'}
  GH_HTTP_BODY=${response%$'\n'*}
  [[ $GH_HTTP_STATUS =~ ^[0-9]{3}$ ]]
}

gh_write() {
  curl -sS --fail-with-body --max-time 60 -X "$1" \
    -H @<(printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nContent-Type: application/json\n' "$2") \
    --data-binary @<(printf '%s' "$4") "$GITHUB_API/$3"
}

fix_changes_valid() {
  local file=$1
  jq -se '
    def path_ok:
      type == "string" and length > 0 and (startswith("/") | not) and
      ((contains("\u0000") or contains("\n") or contains("\r")) | not) and
      (split("/") | all(. != "" and . != "." and . != ".." and . != ".git"));
    length == 1 and (.[0] |
    type == "object" and (keys == ["additions", "deletions"]) and
    (.additions | type == "array") and (.deletions | type == "array") and
    all(.additions[]; type == "object" and (keys == ["contents", "path"]) and
      (.path | path_ok) and (.contents | type == "string" and
        test("^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$"))) and
    all(.deletions[]; type == "object" and (keys == ["path"]) and (.path | path_ok)) and
    (([.additions[].path, .deletions[].path] | length) > 0) and
    (([.additions[].path, .deletions[].path] | length) ==
      ([.additions[].path, .deletions[].path] | unique | length)))
  ' "$file" >/dev/null 2>&1
}

# ponytail: line heuristics for now; a real AST check comes later.
fix_suppression_added() {
  local base_json=$1 new_json=$2
  jq -en --slurpfile b "$base_json" --slurpfile n "$new_json" '
    def suppressed:
      test("#[[:space:]]*noqa|eslint-disable|@ts-ignore|@ts-nocheck|#[[:space:]]*type:[[:space:]]*ignore|\\|\\|[[:space:]]*true|\\|\\|[[:space:]]*:|\\|\\|[[:space:]]*exit 0|set \\+e|continue-on-error: true|pytest\\.mark\\.skip|pytest\\.mark\\.xfail|@pytest\\.mark\\.skip|\\.skip\\(|xit\\(|t\\.Skip\\(");
    ($b[0] | split("\n")) as $base |
    ($n[0] | split("\n")) as $new |
    reduce $new[] as $line ({base: $base, found: false};
      if ($line | suppressed) then
        (.base | index($line)) as $index |
        if $index == null then .found = true else .base = (.base | del(.[$index])) end
      else . end) | .found
  '
}

# ponytail: compares definition lines only; a test whose body is gutted but whose
# definition line stays passes. t2/t3 commits never auto-merge, so review catches it.
fix_test_definitions_removed() {
  local base_json=$1 new_json=$2
  jq -en --slurpfile b "$base_json" --slurpfile n "$new_json" '
    def test_definition:
      test("^[[:space:]]*(async[[:space:]]+)?def test_|^[[:space:]]*(it|test|describe)\\(|^[[:space:]]*func Test|^[[:space:]]*@test |^[[:space:]]*#\\[test\\]");
    ($b[0] | split("\n")) as $base |
    ($n[0] | split("\n")) as $new |
    reduce $base[] as $line ({new: $new, found: false};
      if ($line | test_definition) then
        (.new | index($line)) as $index |
        if $index == null then .found = true else .new = (.new | del(.[$index])) end
      else . end) | .found
  '
}

# Keep credential values in shell memory while scanning binary additions.
# ponytail: verbatim matches only; encoded or split values pass. fix_gitleaks
# covers known secret formats.
fix_contains_credential() {
  local file=$1 value=$2 chunk
  [ -n "$value" ] || return 1
  while IFS= read -r -d '' chunk || [ -n "$chunk" ]; do
    [[ $chunk == *"$value"* ]] && return 0
  done <"$file"
  return 1
}

# fix_gitleaks <dir>: scan the decoded additions with the pinned image's
# gitleaks in a fresh container that has no network and only reads <dir>.
fix_gitleaks() {
  docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges --user "$(id -u):$(id -g)" \
    -v "$1:/scan:ro" --entrypoint gitleaks "$IMAGE" \
    dir /scan --redact --no-banner >/dev/null 2>&1
}

fix_api_path() {
  jq -rn --arg p "$1" '$p | split("/") | map(@uri) | join("/")'
}

# publish_fix_token <id> <run> <container> <token>: all untrusted change
# data is validated before any GitHub write.
publish_fix_token() {
  local id=$1 run=$2 gh=$4 dir="$STATE_DIR/$1" rdir="$STATE_DIR/$1/runs/$2"
  local max_bytes="${AGENT_PUBLISH_MAX_BYTES:-8388608}" max_files="${AGENT_FIX_MAX_FILES:-20}"
  local tmp listing member previous path base64_file base_json new_json api_path suppression_rc changes
  local branch sha headline attempt tier signature body resp rc oid created=0 default_branch pr_url
  local tool router_key_field name value external_bucket="" need_zai=0
  local -a credential_names=() credential_values=()
  local -a members=()
  tmp=$(mktemp -d)
  if [[ ! $max_files =~ ^[0-9]+$ ]]; then
    echo "invalid publisher limit" >"$rdir/reason"
    rm -rf "$tmp"
    return 1
  fi
  listing=$(tar -tf "$5" 2>/dev/null) || {
    echo "guard: invalid fix output archive" >"$rdir/reason"
    rm -rf "$tmp"
    return 1
  }
  while IFS= read -r member; do
    case "$member" in
      .agent-fix/ | ./.agent-fix/ | .agent-fix/changes.json | ./.agent-fix/changes.json | \
        .agent-fix/patch.diff | ./.agent-fix/patch.diff | .agent-fix/summary.txt | ./.agent-fix/summary.txt)
        for previous in "${members[@]}"; do
          if [ "$previous" = "$member" ]; then
            echo "guard: duplicate fix output archive entry" >"$rdir/reason"
            rm -rf "$tmp"
            return 1
          fi
        done
        members+=("$member")
        ;;
      *)
        echo "guard: invalid fix output archive" >"$rdir/reason"
        rm -rf "$tmp"
        return 1
        ;;
    esac
  done <<<"$listing"
  member=""
  for path in "${members[@]}"; do
    if [[ $path == .agent-fix/changes.json || $path == ./.agent-fix/changes.json ]]; then member=$path; fi
  done
  if [ -z "$member" ] || ! tar -xOf "$5" "$member" >"$tmp/changes.json" 2>/dev/null; then
    echo "guard: missing changes.json" >"$rdir/reason"
    rm -rf "$tmp"
    return 1
  fi
  if ! fix_changes_valid "$tmp/changes.json"; then
    echo "guard: invalid changes.json" >"$rdir/reason"
    rm -rf "$tmp"
    return 1
  fi
  if ! jq -sc '.[0]' "$tmp/changes.json" >"$tmp/changes.normalized.json"; then
    echo "guard: invalid changes.json" >"$rdir/reason"
    rm -rf "$tmp"
    return 1
  fi
  changes="$tmp/changes.normalized.json"
  branch=$(job_get "$id" .branch)
  sha=$(job_get "$id" .expected_sha)
  if ! valid_job "$id" || [[ ! $sha =~ ^[0-9a-f]{40}$ ]]; then
    echo "invalid fix metadata" >"$rdir/reason"
    rm -rf "$tmp"
    return 1
  fi
  tool=$(job_get "$id" .tool)
  mapfile -t credential_names < <(jq -r --arg t "$tool" '.[$t].env[]?' <<<"$AGENT_TASK_PROFILES")
  for name in "${credential_names[@]}"; do
    if [ "$name" = ZAI_SUBSCRIPTION_KEY ]; then need_zai=1; fi
  done
  if [ "$need_zai" -eq 1 ]; then
    external_bucket=$(bao_req GET "$ZAI_BUCKET" "${6:-}") || external_bucket=""
  fi
  for name in "${credential_names[@]}"; do
    value=$(credential_value "$name")
    if [ -z "$value" ] || [[ $value == *$'\n'* ]]; then
      echo "guard: credential value unavailable" >"$rdir/reason"
      rm -rf "$tmp"
      return 1
    fi
    credential_values+=("$value")
  done
  router_key_field=$(jq -r --arg t "$tool" '.[$t].routerKeyField // empty' <<<"$AGENT_TASK_PROFILES")
  if [ -n "$router_key_field" ]; then
    value=$(field "$router_key_field")
    if [ -z "$value" ] || [[ $value == *$'\n'* ]] || [[ $value == *$'\r'* ]]; then
      echo "guard: credential value unavailable" >"$rdir/reason"
      rm -rf "$tmp"
      return 1
    fi
    credential_values+=("$value")
    value=${AGENT_ROUTER_BASE_URL#*://}
    value=${value%%/*}
    [ -z "$value" ] || credential_values+=("$value")
  fi
  # ponytail: refuse all .github edits for now; the caller exception comes later.
  if jq -e --argjson max "$max_files" \
    'any(.additions[].path, .deletions[].path; startswith(".github/")) or
     any(.deletions[].path; test("(^|/)(tests?|__tests__|spec|t)/|_tests?\\.|_spec\\.|\\.test\\.|\\.spec\\.|(^|/)(test_[^/]*|tests|conftest)\\.py$")) or
     (([.additions[].path, .deletions[].path] | length) > $max)' \
    "$changes" >/dev/null; then
    if jq -e 'any(.additions[].path, .deletions[].path; startswith(".github/workflows/"))' \
      "$changes" >/dev/null; then
      echo "guard: workflow path" >"$rdir/reason"
    elif jq -e 'any(.additions[].path, .deletions[].path; startswith(".github/"))' \
      "$changes" >/dev/null; then
      echo "guard: github path" >"$rdir/reason"
    elif jq -e 'any(.deletions[].path; test("(^|/)(tests?|__tests__|spec|t)/|_tests?\\.|_spec\\.|\\.test\\.|\\.spec\\.|(^|/)(test_[^/]*|tests|conftest)\\.py$"))' \
      "$changes" >/dev/null; then
      echo "guard: test deletion" >"$rdir/reason"
    else
      echo "guard: too many files" >"$rdir/reason"
    fi
    rm -rf "$tmp"
    return 1
  fi

  jq -r '.additions[].path' "$changes" >"$tmp/paths"
  mkdir "$tmp/scan"
  while IFS= read -r path; do
    base64_file="$tmp/new.b64"
    base_json="$tmp/base.json"
    new_json="$tmp/new.json"
    jq -r --arg p "$path" '.additions[] | select(.path == $p) | .contents' \
      "$changes" >"$base64_file" || {
      echo "guard: invalid base64 contents" >"$rdir/reason"
      rm -rf "$tmp"
      return 1
    }
    base64 -d "$base64_file" >"$tmp/new" 2>/dev/null || {
      echo "guard: invalid base64 contents" >"$rdir/reason"
      rm -rf "$tmp"
      return 1
    }
    if ! jq -Rs . <"$tmp/new" >"$new_json"; then
      echo "guard: invalid added file" >"$rdir/reason"
      rm -rf "$tmp"
      return 1
    fi
    for value in "${credential_values[@]}"; do
      if fix_contains_credential "$tmp/new" "$value"; then
        echo "guard: credential value" >"$rdir/reason"
        rm -rf "$tmp"
        return 1
      fi
    done
    # fix_changes_valid already refused absolute paths and . or .. segments.
    mkdir -p "$tmp/scan/$(dirname "$path")"
    cp "$tmp/new" "$tmp/scan/$path"
    api_path=$(fix_api_path "$path")
    if ! gh_status_get "$gh" "repos/$(job_get "$id" .repo)/contents/$api_path?ref=$sha"; then
      echo "guard: base file lookup failed" >"$rdir/reason"
      rm -rf "$tmp"
      return 1
    fi
    case "$GH_HTTP_STATUS" in
      200)
        if ! jq -e '.encoding == "base64" and (.content | type == "string")' \
          <<<"$GH_HTTP_BODY" >/dev/null; then
          if jq -e '.encoding == "none"' <<<"$GH_HTTP_BODY" >/dev/null; then
            echo "guard: base file too large" >"$rdir/reason"
          else
            echo "guard: base file response invalid" >"$rdir/reason"
          fi
          rm -rf "$tmp"
          return 1
        fi
        jq -r '.content | gsub("\\s"; "")' <<<"$GH_HTTP_BODY" >"$tmp/base.b64"
        if ! base64 -d "$tmp/base.b64" >"$tmp/base" 2>/dev/null || ! jq -Rs . <"$tmp/base" >"$base_json"; then
          echo "guard: base file response invalid" >"$rdir/reason"
          rm -rf "$tmp"
          return 1
        fi
        ;;
      404)
        jq -n '""' >"$base_json"
        ;;
      *)
        echo "guard: base file lookup failed" >"$rdir/reason"
        rm -rf "$tmp"
        return 1
        ;;
    esac
    suppression_rc=0
    if [[ $path =~ (^|/)(tests?|__tests__|spec|t)/|_tests?\.|_spec\.|\.test\.|\.spec\.|(^|/)(test_[^/]*|tests|conftest)\.py$ ]]; then
      fix_test_definitions_removed "$base_json" "$new_json" || suppression_rc=$?
      if [ "$suppression_rc" -eq 0 ]; then
        echo "guard: test removal" >"$rdir/reason"
        rm -rf "$tmp"
        return 1
      elif [ "$suppression_rc" -ne 1 ]; then
        echo "guard: test line comparison failed" >"$rdir/reason"
        rm -rf "$tmp"
        return 1
      fi
    fi
    suppression_rc=0
    fix_suppression_added "$base_json" "$new_json" || suppression_rc=$?
    if [ "$suppression_rc" -eq 0 ]; then
      echo "guard: suppression line" >"$rdir/reason"
      rm -rf "$tmp"
      return 1
    elif [ "$suppression_rc" -ne 1 ]; then
      echo "guard: added line comparison failed" >"$rdir/reason"
      rm -rf "$tmp"
      return 1
    fi
  done <"$tmp/paths"
  unset external_bucket value
  credential_values=()
  if ! fix_gitleaks "$tmp/scan"; then
    echo "guard: gitleaks" >"$rdir/reason"
    rm -rf "$tmp"
    return 1
  fi
  local commit_data gh_rc=0 request
  commit_data="$dir/commit-message.json"
  headline=$(jq -r .headline "$commit_data")
  attempt=$(jq -r .attempt "$commit_data")
  tier=$(jq -r .tier "$commit_data")
  signature=$(jq -r .signature "$commit_data")
  body=$(printf 'CI-Resolver-Attempt: %s\nCI-Resolver-Tier: %s\nCI-Resolver-Signature: %s\n\nAssisted-by: %s (nix-agent-sandbox)' \
    "$attempt" "$tier" "$signature" "$(job_get "$id" .tool)")
  if ! gh_status_get "$gh" "repos/$(job_get "$id" .repo)/git/ref/heads/$branch"; then
    echo "github branch lookup failed" >"$rdir/reason"
    rm -rf "$tmp"
    return 1
  fi
  case "$GH_HTTP_STATUS" in
    200) ;;
    404)
      request=$(jq -cn --arg r "refs/heads/$branch" --arg s "$sha" '{ref: $r, sha: $s}')
      resp=$(gh_write POST "$gh" "repos/$(job_get "$id" .repo)/git/refs" "$request" 2>/dev/null) || resp=""
      if [ -z "$resp" ]; then
        echo "head moved" >"$rdir/reason"
        rm -rf "$tmp"
        return 1
      fi
      created=1
      ;;
    *)
      echo "github branch lookup failed" >"$rdir/reason"
      rm -rf "$tmp"
      return 1
      ;;
  esac
  jq -n --slurpfile changes "$changes" --arg repo "$(job_get "$id" .repo)" \
    --arg branch "$branch" --arg sha "$sha" --arg headline "$headline" --arg body "$body" \
    --arg query 'mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }' \
    '{query: $query, variables: {input: {branch: {repositoryNameWithOwner: $repo, branchName: $branch},
      expectedHeadOid: $sha, message: {headline: $headline, body: $body},
      fileChanges: {additions: $changes[0].additions, deletions: $changes[0].deletions}}}}' \
    >"$tmp/graphql.json" || {
    echo "github commit request invalid" >"$rdir/reason"
    rm -rf "$tmp"
    return 1
  }
  if ! curl -sS --fail-with-body --max-time 60 -X POST \
    -H @<(printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nContent-Type: application/json\n' "$gh") \
    --data-binary @"$tmp/graphql.json" "$GITHUB_API/graphql" >"$tmp/graphql.response" 2>/dev/null; then gh_rc=1; fi
  resp=$(cat "$tmp/graphql.response" 2>/dev/null || true)
  if [ "$gh_rc" -ne 0 ] || jq -e '(.errors | type == "array" and length > 0) or (.data.createCommitOnBranch.commit.oid | type != "string")' \
    <<<"$resp" >/dev/null 2>&1; then
    if jq -er '[.errors[]?.message // ""] | join(" ") | test("(?i)(head.*moved|expected.*head|head.*expected|updated since)")' \
      <<<"$resp" >/dev/null 2>&1; then
      echo "head moved" >"$rdir/reason"
    else
      echo "github commit rejected" >"$rdir/reason"
    fi
    if [ "$created" = 1 ]; then
      curl -sS --max-time 30 -o /dev/null -X DELETE \
        -H @<(printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\n' "$gh") \
        "$GITHUB_API/repos/$(job_get "$id" .repo)/git/refs/heads/$branch" >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp"
    return 1
  fi
  oid=$(jq -r '.data.createCommitOnBranch.commit.oid' <<<"$resp")
  if [[ ! $oid =~ ^[0-9a-f]{40}$ ]]; then
    echo "github commit response invalid" >"$rdir/reason"
    rm -rf "$tmp"
    return 1
  fi
  echo "$oid" >"$dir/commit"
  if [ "$created" = 1 ]; then
    if ! gh_status_get "$gh" "repos/$(job_get "$id" .repo)" || \
      [[ $GH_HTTP_STATUS != 200 ]]; then
      echo "default branch lookup failed" >"$rdir/reason"
      rm -rf "$tmp"
      return 1
    fi
    default_branch=$(jq -r '.default_branch // empty' <<<"$GH_HTTP_BODY")
    if [ -z "$default_branch" ]; then
      echo "default branch lookup failed" >"$rdir/reason"
      rm -rf "$tmp"
      return 1
    fi
    request=$(jq -cn --arg title "$headline" --arg head "$branch" --arg base "$default_branch" \
      '{title: $title, head: $head, base: $base, draft: false, body: ""}')
    resp=$(gh_write POST "$gh" "repos/$(job_get "$id" .repo)/pulls" "$request" 2>/dev/null) || resp=""
    pr_url=$(jq -r '.html_url // empty' <<<"$resp")
    if [[ $pr_url =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$ ]]; then
      echo "$pr_url" >"$dir/pr_url"
    else
      echo "pull request creation failed" >"$rdir/reason"
      rm -rf "$tmp"
      return 1
    fi
  fi
  echo succeeded >"$rdir/fix_state"
  rm -rf "$tmp"
}

# publish_fix <id> <run> <container> <service-token>: mint the write token
# only after the container has exited, then revoke it on every path.
publish_fix() {
  local id=$1 run=$2 cid=$3 tok=$4 repo iid bucket mint gh
  local rdir="$STATE_DIR/$1/runs/$2"
  local tmp request max_bytes="${AGENT_PUBLISH_MAX_BYTES:-8388608}" archive_size cp_rc rc=0
  repo=$(job_get "$id" .repo)
  tmp=$(mktemp -d)
  if [[ ! $max_bytes =~ ^[0-9]+$ ]]; then
    echo "invalid publisher limit" >"$rdir/reason"
    rm -rf "$tmp"
    return 1
  fi
  if ! docker cp "$cid:/home/agent/work/.agent-fix" - 2>"$tmp/cp.err" | \
    head -c "$((max_bytes + 1))" >"$tmp/fix.tar"; then cp_rc=1; else cp_rc=0; fi
  archive_size=$(wc -c <"$tmp/fix.tar")
  if [ "$archive_size" -gt "$max_bytes" ]; then
    echo "guard: output exceeds ${max_bytes} bytes" >"$rdir/reason"
    rm -rf "$tmp"
    return 1
  fi
  if [ "$cp_rc" -ne 0 ]; then
    if [[ $(<"$tmp/cp.err") == *"Could not find the file"* ]]; then
      echo no-change >"$rdir/fix_state"
      rm -rf "$tmp"
      return 0
    fi
    echo "fix outputs could not be copied" >"$rdir/reason"
    rm -rf "$tmp"
    return 1
  fi
  bucket=$(bao_req GET "$BUCKET" "$tok") || bucket=""
  iid=$(field GITHUB_AGENTS_INSTALLATION_ID)
  if [ -z "$iid" ]; then
    echo "bucket has no GITHUB_AGENTS_INSTALLATION_ID" >"$rdir/reason"
    rm -rf "$tmp"
    return 1
  fi
  request=$(jq -cn --arg i "$iid" --arg r "${repo#*/}" \
    '{installation_id: $i, repositories: $r, permissions: {contents: "write", pull_requests: "write"}}')
  mint=$(bao_req POST github-agents/token "$tok" "$request") || mint=""
  gh=$(jq -r '.data.token // empty' <<<"$mint")
  if [ -z "$gh" ] || ! scope_ok "$gh" "$repo"; then
    if [ -n "$gh" ]; then gh_revoke "$gh"; fi
    echo "github token is not scoped to exactly $repo" >"$rdir/reason"
    rm -rf "$tmp"
    return 1
  fi
  if publish_fix_token "$id" "$run" "$cid" "$gh" "$tmp/fix.tar" "$tok"; then rc=0; else rc=$?; fi
  gh_revoke "$gh"
  rm -rf "$tmp"
  return "$rc"
}

# finalize <id> <run>: settle a run's terminal state once, remove its
# container (the volume stays for `continue`), and post the result.
redact_log_values() {
  local line value
  while IFS= read -r line || [ -n "$line" ]; do
    for value in "${JOB_REDACT_VALUES[@]}"; do
      # Skip short values to avoid masking normal text.
      [ "${#value}" -ge 8 ] || continue
      line=${line//"$value"/'[REDACTED]'}
    done
    printf '%s\n' "$line"
  done
}

finalize() {
  local id=$1 run=$2 tok=${3:-} rdir="$STATE_DIR/$1/runs/$2" state cid code pr mode
  mkdir "$rdir/final" 2>/dev/null || return 0
  if [ "${#JOB_REDACT_VALUES[@]}" -eq 0 ] && [ -f "$rdir/redact-values" ]; then
    mapfile -t JOB_REDACT_VALUES <"$rdir/redact-values"
  fi
  code=$(cat "$rdir/exit" 2>/dev/null || true)
  cid=$(cat "$rdir/cid" 2>/dev/null || true)
  mode=$(job_get "$id" .mode 2>/dev/null || echo start)
  if [ -f "$rdir/reason" ]; then
    state=failed
  elif [ -e "$rdir/cancel" ]; then
    state=cancelled
  elif [ -e "$rdir/timeout" ]; then
    state=timeout
  elif [ "$code" = 0 ]; then
    if [ "$mode" = fix ]; then
      if [ -n "$cid" ] && publish_fix "$id" "$run" "$cid" "$tok"; then
        state=$(cat "$rdir/fix_state" 2>/dev/null || echo succeeded)
      else
        state=failed
        [ -f "$rdir/reason" ] || echo "fix publish failed" >"$rdir/reason"
      fi
    else
      state=succeeded
    fi
  else
    state=failed
    echo "exit ${code:-unknown}" >"$rdir/reason"
  fi
  if [ -n "$cid" ]; then
    if [ "$mode" != fix ]; then
      pr=$(read_pr_url "$cid" "$(job_get "$id" .repo)")
      if [ -n "$pr" ]; then echo "$pr" >"$STATE_DIR/$id/pr_url"; fi
    fi
    if docker logs --tail 200 "$cid" 2>/dev/null | redact_log_values | jq -Rr \
      'gsub("(?i)(?<prefix>(?:authorization|x-vault-token):[[:space:]]*).*"; "\(.prefix)[REDACTED]") |
       gsub("(?i)(?<prefix>[A-Z0-9_.-]*(?:KEY|TOKEN|SECRET|PASSWORD|AUTH)[A-Z0-9_.-]*=).*"; "\(.prefix)[REDACTED]") |
       gsub("(?i)(?<prefix>\"[A-Z0-9_.-]*(?:KEY|TOKEN|SECRET|PASSWORD|AUTH)[A-Z0-9_.-]*\"[[:space:]]*:[[:space:]]*)\"[^\"]*\""; "\(.prefix)\"[REDACTED]\"") |
       gsub("ghs_[A-Za-z0-9_-]+|gho_[A-Za-z0-9_-]+|ghu_[A-Za-z0-9_-]+|github_pat_[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]+|(?i)bearer[[:space:]]+[^[:space:]]+"; "[REDACTED]")' \
      >"$rdir/log"; then
      :
    else
      : >"$rdir/log"
    fi
    chmod 600 "$rdir/log"
    docker rm -f "$cid" >/dev/null 2>&1 || true
  fi
  rm -f "$rdir/redact-values"
  date +%s >"$rdir/ended"
  echo "$state" >"$rdir/state"
  if [ -n "$tok" ]; then
    notify "$id" "$run" "$tok" || echo "agent-dispatch: $id: result notification incomplete" >&2
  fi
}

# abort <id> <run> <reason> [job-token]: fail the run closed and print
# the job JSON.
abort() {
  echo "$3" >"$STATE_DIR/$1/runs/$2/reason"
  finalize "$1" "$2" "${4:-}"
  if [ -n "${4:-}" ] && [ "$JOB_MANAGER" -eq 0 ]; then bao_revoke "$4"; fi
  job_json "$1"
}

abort_login() {
  local id=$1 run=$2 reason=$3
  echo "$reason" >"$STATE_DIR/$id/runs/$run/reason"
  finalize "$id" "$run"
  notify_login_refused "$reason" || echo "agent-dispatch: $id: login refusal alert incomplete" >&2
  job_json "$id"
}

# container_args <id> <run> <tool> <repo> <continue> <tty> <mode>:
# the `docker create` arguments, into $args. Only non-secret values appear
# here.
container_args() {
  local proxy="${AGENT_PROXY_URL:-http://proxy:3128}"
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
    -e AGENT_DISPATCHED_JOB=1
    -e "AGENT_REPO=$4"
    -e "AGENT_RUN_ID=$1"
    -v "agent-job-$1:/home/agent/work"
    --memory "${AGENT_MEMORY:-$AGENT_MEMORY_DEFAULT}"
    --cpus "${AGENT_CPUS:-$AGENT_CPUS_DEFAULT}"
    --pids-limit "${AGENT_PIDS_LIMIT:-$AGENT_PIDS_LIMIT_DEFAULT}"
    --security-opt no-new-privileges
    --cap-drop ALL
  )
  if [ "$7" = fix ]; then
    args+=(--label agent-dispatch.mode=fix -e AGENT_MODE=fix
      -e "AGENT_BRANCH=$(job_get "$1" .branch)"
      -e "AGENT_EXPECTED_SHA=$(job_get "$1" .expected_sha)")
  else
    args+=(-e AGENT_PR_DRAFT=1)
  fi
  if [ "$5" = 1 ]; then args+=(-e AGENT_CONTINUE=1); fi
  if [ "$6" = 1 ]; then args+=(--interactive --tty -e AGENT_TTY=1); fi
  args+=("$IMAGE")
}

# deliver <cid> <prompt> <mode>: the run's secrets (NAME=value lines) and prompt, as
# files owned by the container's uid 1000, streamed in with `docker cp`.
# Uses the caller's $names, $bucket, $gh and optional router key.
deliver() {
  local tmp name value rc=0
  tmp=$(mktemp -d)
  {
    JOB_REDACT_VALUES=()
    if [ "$3" != fix ]; then
      printf 'GH_TOKEN=%s\nGITHUB_TOKEN=%s\n' "$gh" "$gh"
      JOB_REDACT_VALUES+=("$gh")
    fi
    printf 'BAO_ADDR=%s\nSANDBOX_ROLE_ID=%s\nSANDBOX_WRAPPED_SECRET_ID=%s\n' \
      "$BAO_ADDR" "$sandbox_role_id" "$sandbox_wrapped_secret_id"
    JOB_REDACT_VALUES+=("$sandbox_role_id" "$sandbox_wrapped_secret_id")
    printf 'GIT_MIRROR_URL=%s\nVIKUNJA_URL=%s\nZAMMAD_URL=%s\n' \
      "$GIT_MIRROR_URL" "$VIKUNJA_URL" "$ZAMMAD_URL"
    for name in "${names[@]}"; do
      value=$(credential_value "$name")
      single_line "$value" || rc=1
      printf '%s=%s\n' "$name" "$value"
      JOB_REDACT_VALUES+=("$value")
    done
    if [ -n "$router_key_field" ]; then
      printf 'AGENT_ROUTER_BASE_URL=%s\n' "$AGENT_ROUTER_BASE_URL"
    fi
  } >"$tmp/.agent-env"
  chmod 600 "$tmp/.agent-env"
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
  local tool repo mode tty tty_login cont=0 login tok lease bucket external_bucket="" iid mint gh="" budget cid name request
  local router_key_field="" sandbox_role_id="" sandbox_wrapped_secret_id="" sandbox_role="" role_response wrapped_response reason value
  local -a names args
  JOB_REDACT_VALUES=()
  tool=$(job_get "$id" .tool)
  repo=$(job_get "$id" .repo)
  mode=$(job_get "$id" '(.mode // "start")')
  tty=$(job_get "$id" 'if .tty then 1 else 0 end')
  # A terminal session of a login tool: the user signs in by hand, so the
  # container gets no router key and no provider key.
  tty_login=0
  if [ "$tty" = 1 ] && jq -e --arg t "$tool" '.[$t].ttyLogin == true' <<<"$AGENT_TASK_PROFILES" >/dev/null; then
    tty_login=1
  fi
  if [ "$run" != 1 ]; then cont=1; fi
  date +%s >"$rdir/started"
  echo starting >"$rdir/state"

  if [ "$run" = 1 ]; then
    if ! service_login; then
      abort_login "$id" "$run" "$reason"
      return 1
    fi
    tok=$(jq -r '.auth.client_token' <<<"$login")
    lease=$(jq -r '.auth.lease_duration // 0' <<<"$login")
  else
    tok=${4:-}
    lease=$JOB_TOKEN_TTL
  fi
  unset login
  [ -n "$tok" ] || {
    abort "$id" "$run" "job token is empty"
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
  for name in "${names[@]}"; do
    if [ "$name" = ZAI_SUBSCRIPTION_KEY ]; then
      external_bucket=$(bao_req GET "$ZAI_BUCKET" "$tok") || {
        abort "$id" "$run" "external credential read failed" "$tok"
        return 1
      }
      break
    fi
  done
  if [ "$tty_login" = 1 ]; then names=(); fi
  jq -e --arg t "$tool" 'has($t)' <<<"$AGENT_TASK_PROFILES" >/dev/null || {
    abort "$id" "$run" "no task profile for $tool" "$tok"
    return 1
  }
  for name in "${names[@]}"; do
    value=$(credential_value "$name")
    if [ -n "$value" ] && single_line "$value"; then :; else
      abort "$id" "$run" "profile credential is missing or invalid" "$tok"
      return 1
    fi
  done
  router_key_field=$(jq -r --arg t "$tool" '.[$t].routerKeyField // empty' <<<"$AGENT_TASK_PROFILES")
  if [ "$tty_login" = 1 ]; then router_key_field=""; fi
  if [ -n "$router_key_field" ]; then
    if [ -z "${AGENT_ROUTER_BASE_URL:-}" ] || [[ $AGENT_ROUTER_BASE_URL == *$'\n'* ]] || \
      [[ $AGENT_ROUTER_BASE_URL == *$'\r'* ]]; then
      abort "$id" "$run" "router configuration is missing or invalid" "$tok"
      return 1
    fi
  fi

  if [ -z "${BAO_ADDR:-}" ] || [ -z "${GIT_MIRROR_URL:-}" ] || \
    [ -z "${VIKUNJA_URL:-}" ] || [ -z "${ZAMMAD_URL:-}" ] || \
    ! single_line "$BAO_ADDR" || ! single_line "$GIT_MIRROR_URL" || \
    ! single_line "$VIKUNJA_URL" || ! single_line "$ZAMMAD_URL" || \
    [[ ! $BAO_ADDR =~ ^https?://[^[:space:]]+$ ]]; then
    abort "$id" "$run" "sandbox service configuration is missing or invalid" "$tok"
    return 1
  fi

  if [ "$mode" = fix ]; then
    request=$(jq -cn --arg i "$iid" --arg r "${repo#*/}" \
      '{installation_id: $i, repositories: $r, permissions: {contents: "read"}}')
    mint=$(bao_req POST github-agents/token "$tok" "$request") || {
      abort "$id" "$run" "github token mint refused for $repo" "$tok"
      return 1
    }
  else
  # One repo, contents + pull requests only (no workflow edits). The
  # installation id and repo travel as strings, the form the policy matches.
  mint=$(bao_req POST github-agents/token "$tok" "$(jq -cn --arg i "$iid" --arg r "${repo#*/}" \
    '{installation_id: $i, repositories: $r,
      permissions: {contents: "write", pull_requests: "write"}}')") || {
    abort "$id" "$run" "github token mint refused for $repo" "$tok"
    return 1
  }
  fi
  gh=$(jq -r '.data.token // empty' <<<"$mint")
  if [ -z "$gh" ] || ! single_line "$gh" || ! scope_ok "$gh" "$repo"; then
    if [ -n "$gh" ]; then gh_revoke "$gh"; fi
    abort "$id" "$run" "github token is not scoped to exactly $repo" "$tok"
    return 1
  fi
  reason=$(repo_guard "$gh" "$repo")
  if [ -n "$reason" ]; then
    gh_revoke "$gh"
    abort "$id" "$run" "$reason" "$tok"
    return 1
  fi
  if [ "$mode" = fix ]; then
    gh_revoke "$gh"
    gh=""
  fi

  sandbox_role=sandbox-agent-write
  if [ "$mode" = fix ]; then sandbox_role=sandbox-agent-read; fi
  role_response=$(bao_req GET "auth/approle/role/$sandbox_role/role-id" "$tok") || {
    abort "$id" "$run" "sandbox role lookup failed" "$tok"
    return 1
  }
  sandbox_role_id=$(jq -r '.data.role_id // empty' <<<"$role_response")
  if [ -z "$sandbox_role_id" ] || ! single_line "$sandbox_role_id"; then
    abort "$id" "$run" "sandbox role lookup returned no role ID" "$tok"
    return 1
  fi
  wrapped_response=$(bao_wrap_req "$sandbox_role" "$tok") || {
    abort "$id" "$run" "sandbox SecretID wrapping failed" "$tok"
    return 1
  }
  sandbox_wrapped_secret_id=$(jq -r '.wrap_info.token // empty' <<<"$wrapped_response")
  if [ -z "$sandbox_wrapped_secret_id" ] || ! single_line "$sandbox_wrapped_secret_id"; then
    abort "$id" "$run" "sandbox SecretID wrapping returned no token" "$tok"
    return 1
  fi

  budget="${AGENT_TIMEOUT:-$AGENT_TIMEOUT_DEFAULT}"
  echo "$budget" >"$rdir/budget"
  echo "$lease" >"$rdir/ttl"
  container_args "$id" "$run" "$tool" "$repo" "$cont" "$tty" "$mode"
  cid=$(docker create "${args[@]}") || {
    bao_revoke_wrap "$sandbox_wrapped_secret_id"
    abort "$id" "$run" "container create failed" "$tok"
    return 1
  }
  echo "$cid" >"$rdir/cid"
  deliver "$cid" "$prompt" "$mode" || {
    bao_revoke_wrap "$sandbox_wrapped_secret_id"
    abort "$id" "$run" "credential delivery failed" "$tok"
    return 1
  }
  # Refresh can finalize a stopped job after its in-memory manager is gone.
  if ! (umask 077 && printf '%s\n' "${JOB_REDACT_VALUES[@]}" >"$rdir/redact-values") ||
    ! chmod 600 "$rdir/redact-values"; then
    rm -f "$rdir/redact-values"
    abort "$id" "$run" "credential redaction handoff failed" "$tok"
    return 1
  fi
  docker start "$cid" >/dev/null || {
    bao_revoke_wrap "$sandbox_wrapped_secret_id"
    abort "$id" "$run" "container start failed" "$tok"
    return 1
  }
  unset bucket external_bucket value role_response wrapped_response sandbox_role_id sandbox_wrapped_secret_id
  echo running >"$rdir/state"

  if [ "$JOB_MANAGER" -eq 1 ]; then
    job_json "$id"
    return 0
  fi

  # The waiter receives the token on stdin and retains it in memory for the
  # entire job. It alone renews, notifies, and starts later continuations.
  mkdir "$STATE_DIR/$id/manager" || {
    abort "$id" "$run" "job manager already exists" "$tok"
    return 1
  }
  if ! printf '%s\n' "$tok" "${JOB_REDACT_VALUES[@]}" | setsid -f "$0" __job "$id" "$run" \
    >>"$STATE_DIR/$id/dispatch.log" 2>&1; then
    rmdir "$STATE_DIR/$id/manager" 2>/dev/null || true
    abort "$id" "$run" "job manager start failed" "$tok"
    return 1
  fi
  job_json "$id"
}

# wait_run <id> <run> <token>: wait for one container and renew the in-memory
# job token while it runs.
wait_run() {
  local id=$1 run=$2 tok=$3 rdir="$STATE_DIR/$1/runs/$2" cid code rc ttl step
  local now end deadline expiry slice renewed lease job_end=0
  JOB_ENDED=0
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
      job_end=1
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
      echo "service token renewal failed" >"$rdir/reason"
      job_end=1
      docker kill "$cid" >/dev/null 2>&1 || true
      break
    fi
    # At the max TTL the renewal comes back short; the run then ends with
    # the token.
    expiry=$(($(date +%s) + lease))
    JOB_TOKEN_TTL=$lease
  done
  finalize "$id" "$run" "$tok"
  now=$(date +%s)
  JOB_TOKEN_TTL=$((expiry - now))
  if [ "$JOB_TOKEN_TTL" -lt 0 ]; then JOB_TOKEN_TTL=0; fi
  if [ "$job_end" -eq 1 ]; then JOB_ENDED=1 JOB_TOKEN_TTL=0; fi
}

# The manager owns the token for the job's lifetime. Continue requests are
# non-secret prompt files in new run directories; the token never touches disk.
job_loop() {
  local id=$1 run=$2 tok="" credential rdir latest next prompt now idle_until manager_dir
  manager_dir="$STATE_DIR/$id/manager"
  IFS= read -r tok || true
  JOB_REDACT_VALUES=()
  while IFS= read -r credential; do JOB_REDACT_VALUES+=("$credential"); done
  if [ -z "$tok" ]; then
    rmdir "$manager_dir" 2>/dev/null || true
    return 1
  fi
  JOB_MANAGER=1
  printf '%s\n' "$$" >"$manager_dir/pid"
  trap 'if [ -n "$tok" ]; then bao_revoke "$tok"; fi; rmdir "$manager_dir" 2>/dev/null || true' EXIT
  trap 'exit 0' HUP INT TERM

  while [ -d "$STATE_DIR/$id" ]; do
    rdir="$STATE_DIR/$id/runs/$run"
    if [ ! -d "$rdir/final" ] && [ -f "$rdir/cid" ]; then
      wait_run "$id" "$run" "$tok"
      [ "$JOB_ENDED" -eq 0 ] || break
    fi
    idle_until=$(($(date +%s) + JOB_TOKEN_TTL))

    while [ -d "$STATE_DIR/$id" ]; do
      [ ! -e "$STATE_DIR/$id/end" ] || break 2
      now=$(date +%s)
      if [ "$now" -ge "$idle_until" ]; then break 2; fi
      latest=$(latest_run "$id")
      if [ "$latest" -gt "$run" ]; then
        next=$latest
        rdir="$STATE_DIR/$id/runs/$next"
        if [ -f "$rdir/prompt" ]; then
          prompt=$(cat "$rdir/prompt"; printf '.')
          prompt=${prompt%.}
          rm -f "$rdir/prompt"
          run=$next
          run_job "$id" "$run" "$prompt" "$tok" || true
          break
        fi
      fi
      sleep 1
    done
  done

  bao_revoke "$tok"
  tok=""
  JOB_MANAGER=0
  trap - EXIT
  rmdir "$manager_dir" 2>/dev/null || true
}

job_exists() {
  valid_job "$1" || refuse "invalid job id"
  [ -f "$STATE_DIR/$1/job.json" ] || {
    jq -cn --arg job "$1" '{job: $job, error: "no such job"}'
    exit 1
  }
}

decode_header_value() {
  local value=$1 i=0 char hex code
  decoded_value=""
  while [ "$i" -lt "${#value}" ]; do
    char=${value:$i:1}
    case "$char" in
      +) decoded_value+=" "; i=$((i + 1)) ;;
      %)
        hex=${value:$((i + 1)):2}
        [[ $hex =~ ^[0-9A-Fa-f]{2}$ ]] || return 1
        code=$((16#$hex))
        [ "$code" -ge 32 ] && [ "$code" -ne 127 ] || return 1
        printf -v char '%b' "\\x$hex"
        decoded_value+="$char"
        i=$((i + 3))
        ;;
      [-A-Za-z0-9._~]) decoded_value+="$char"; i=$((i + 1)) ;;
      *) return 1 ;;
    esac
  done
}

parse_fix_prompt() {
  local header=${1%%$'\n'*} rest re
  local encoded
  re='^CI-RESOLVER headline=([-A-Za-z0-9._~+]|%[0-9A-Fa-f]{2})+ attempt=([1-9]) tier=(t[123]) signature=([0-9a-f]{12})$'
  [[ $header =~ $re ]] || return 1
  encoded=${header#CI-RESOLVER headline=}
  encoded=${encoded%% attempt=*}
  attempt=${BASH_REMATCH[2]}
  tier=${BASH_REMATCH[3]}
  signature=${BASH_REMATCH[4]}
  decode_header_value "$encoded" || return 1
  headline=$decoded_value
  re='^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([a-z0-9-]+\))?(!)?: .{1,100}$'
  [[ $headline =~ $re ]] || return 1
  rest=${1#*$'\n'}
  [ "$rest" != "$1" ] || return 1
  fix_task=$rest
}

cmd_start() {
  local tty=0 tool repo prompt id dir reason
  if [ "${1:-}" = --tty ]; then
    tty=1
    shift
  fi
  if [ "$tty" = 1 ]; then
    [ $# -eq 2 ] || usage
  else
    [ $# -eq 3 ] || usage
  fi
  tool=$1 repo=$2 prompt=${3:-}
  valid_tool "$tool" || refuse "unknown tool"
  valid_repo "$repo" || refuse "invalid owner/repo"
  reason=$(repo_scope_guard "$repo")
  [ -z "$reason" ] || refuse "$reason"
  if [ "$tty" = 0 ]; then
    valid_text "$prompt" || refuse "invalid prompt"
    [[ ${prompt%%$'\n'*} != CI-RESOLVER* ]] || refuse "CI-RESOLVER header requires fix"
    # A batch job needs a credential it can use without a person.
    jq -e --arg t "$tool" '.[$t] | has("routerKeyField") or (.env | length > 0)' \
      <<<"$AGENT_TASK_PROFILES" >/dev/null || refuse "$tool runs only as a terminal session (--tty)"
  else
    jq -e --arg t "$tool" '.[$t].ttyLogin == true' \
      <<<"$AGENT_TASK_PROFILES" >/dev/null || refuse "$tool has no terminal session"
  fi
  id="j-$(rand_hex 8)"
  dir="$STATE_DIR/$id"
  mkdir -p "$STATE_DIR"
  mkdir "$dir"
  mkdir -p "$dir/runs/1"
  jq -n --arg job "$id" --arg tool "$tool" --arg repo "$repo" \
    --argjson t "$tty" '{job: $job, tool: $tool, repo: $repo, tty: ($t == 1)}' \
    >"$dir/job.json"
  run_job "$id" 1 "$prompt" || return 1
  if [ "$tty" = 1 ]; then attach "$id"; fi
}

cmd_fix() {
  local tool repo branch sha raw_prompt prompt id dir cap running count=0 line tier reason
  [ $# -eq 5 ] || usage
  tool=$1 repo=$2 branch=$3 sha=$4 raw_prompt=$5
  [[ $tool != -* ]] || refuse "unknown tool"
  # shell is fix-only, so it stays out of valid_tool (the start and client list).
  [ "$tool" = shell ] || valid_tool "$tool" || refuse "unknown tool"
  valid_repo "$repo" || refuse "invalid owner/repo"
  valid_branch "$branch" || refuse "invalid branch"
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || refuse "invalid expected sha"
  parse_fix_prompt "$raw_prompt" || refuse "invalid CI-RESOLVER header"
  if { [ "$tier" = t1 ] && [ "$tool" != shell ]; } || \
    { [ "$tier" != t1 ] && [ "$tool" = shell ]; }; then
    refuse "invalid CI-RESOLVER header"
  fi
  prompt=$fix_task
  valid_text "$prompt" || refuse "invalid prompt"
  reason=$(repo_scope_guard "$repo")
  [ -z "$reason" ] || refuse "$reason"
  # shell runs the workbook's deterministic command and needs no model credential.
  [ "$tool" = shell ] || jq -e --arg t "$tool" '.[$t] | has("routerKeyField") or (.env | length > 0)' \
    <<<"$AGENT_TASK_PROFILES" >/dev/null || refuse "$tool runs only as a terminal session"
  cap=${AGENT_FIX_MAX_CONCURRENT:-3}
  [[ $cap =~ ^[0-9]+$ ]] || refuse "invalid AGENT_FIX_MAX_CONCURRENT"
  running=$(docker ps --quiet --filter label=agent-dispatch.mode=fix --filter status=running) || {
    jq -cn '{error: "concurrency check failed"}'
    return 1
  }
  while IFS= read -r line; do
    [ -n "$line" ] && count=$((count + 1))
  done <<<"$running"
  if [ "$count" -ge "$cap" ]; then
    jq -cn '{error: "busy"}'
    return 75
  fi
  id="j-$(rand_hex 8)"
  dir="$STATE_DIR/$id"
  mkdir -p "$STATE_DIR"
  mkdir "$dir"
  mkdir -p "$dir/runs/1"
  jq -n --arg job "$id" --arg tool "$tool" --arg repo "$repo" --arg branch "$branch" \
    --arg sha "$sha" '{job: $job, tool: $tool, repo: $repo, tty: false,
      mode: "fix", branch: $branch, expected_sha: $sha}' >"$dir/job.json"
  jq -n --arg headline "$headline" --arg attempt "$attempt" --arg tier "$tier" \
    --arg signature "$signature" '{headline: $headline, attempt: $attempt, tier: $tier, signature: $signature}' \
    >"$dir/commit-message.json"
  run_job "$id" 1 "$prompt" || return 1
}

# attach <id>: the caller's terminal joins the running container. The waiter
# still owns the job. When the session ends early (hang-up or detach), the
# container is killed and the run settles as cancelled.
attach() {
  local rdir="$STATE_DIR/$1/runs/1" cid
  cid=$(cat "$rdir/cid")
  trap 'end_session "$rdir" "$cid"; exit 0' HUP INT TERM
  docker attach --detach-keys ctrl-^,ctrl-^ "$cid" || true
  end_session "$rdir" "$cid"
}

end_session() {
  if [ "$(docker inspect -f '{{.State.Running}}' "$2" 2>/dev/null)" = true ]; then
    : >"$1/cancel"
    docker kill "$2" >/dev/null 2>&1 || true
  fi
}

cmd_continue() {
  local id last next dir rdir manager_pid prompt tries=0 reason
  [ $# -eq 2 ] || usage
  id=$1
  valid_job "$id" || refuse "invalid job id"
  valid_text "$2" || refuse "invalid message"
  job_exists "$id"
  [ "$(job_get "$id" '(.mode // "start")')" != fix ] || refuse "fix jobs run once; start a new job"
  reason=$(repo_scope_guard "$(job_get "$id" .repo)")
  [ -z "$reason" ] || refuse "$reason"
  if [ "$(job_get "$id" .tty)" = true ]; then
    refuse "a terminal job ends with its session"
  fi
  dir="$STATE_DIR/$id"
  last=$(latest_run "$id")
  [ -d "$dir/runs/$last/final" ] || {
    job_json "$id"
    echo "agent-dispatch: job is still running" >&2
    exit 1
  }
  manager_pid=$(cat "$dir/manager/pid" 2>/dev/null || true)
  if [[ ! $manager_pid =~ ^[0-9]+$ ]] || ! kill -0 "$manager_pid" 2>/dev/null; then
    refuse "job token is unavailable; start a new job"
  fi
  next=$((last + 1))
  rdir="$dir/runs/$next"
  mkdir "$rdir" 2>/dev/null || {
    echo "agent-dispatch: job is busy" >&2
    exit 1
  }
  date +%s >"$rdir/started"
  echo starting >"$rdir/state"
  printf '%s' "$2" >"$rdir/prompt"
  chmod 600 "$rdir/prompt"
  while [ "$tries" -lt 50 ]; do
    [ -f "$rdir/cid" ] || [ -d "$rdir/final" ] && break
    manager_pid=$(cat "$dir/manager/pid" 2>/dev/null || true)
    if [[ ! $manager_pid =~ ^[0-9]+$ ]] || ! kill -0 "$manager_pid" 2>/dev/null; then
      echo "job token expired" >"$rdir/reason"
      finalize "$id" "$next"
      job_json "$id"
      echo "agent-dispatch: job token is unavailable; start a new job" >&2
      exit 1
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  job_json "$id"
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

# check: one login, then revoke, so a credential that stops working alerts
# before a job needs it.
cmd_check() {
  local login reason
  if ! service_login; then
    notify_login_refused "$reason" || echo "agent-dispatch: check: login refusal alert incomplete" >&2
    jq -cn --arg r "$reason" '{login: "refused", reason: $r}'
    return 1
  fi
  bao_revoke "$(jq -r '.auth.client_token' <<<"$login")"
  jq -cn '{login: "ok"}'
}

# refresh: settle runs whose waiter is gone, then prune finished jobs older
# than AGENT_DISPATCH_RETENTION seconds (container, volume and state).
cmd_refresh() {
  local now dir id rdir cid status ended manager_pid i keep="${AGENT_DISPATCH_RETENTION:-86400}"
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
      ended=$(cat "$rdir/ended" 2>/dev/null || echo "$now")
      if [ $((now - ended)) -ge "$keep" ]; then
        : >"$dir/end"
        manager_pid=$(cat "$dir/manager/pid" 2>/dev/null || true)
        if [[ $manager_pid =~ ^[0-9]+$ ]] && kill -0 "$manager_pid" 2>/dev/null; then
          for ((i = 0; i < 50; i++)); do
            [ -d "$dir/manager" ] || break
            sleep 0.1
          done
        fi
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
  fix) cmd_fix "$@" ;;
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
  check)
    [ $# -eq 0 ] || usage
    cmd_check
    ;;
  __job)
    # Internal: the detached job manager run_job starts. Not reachable over SSH.
    if [ $# -ne 2 ] || ! valid_job "$1" || [[ ! $2 =~ ^[0-9]+$ ]]; then usage; fi
    job_loop "$1" "$2"
    ;;
  *) usage ;;
esac
