export LC_ALL=C
# Set before any use, so an inherited environment value cannot mark a job as submitted.
submitted=0

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  printf '%s\n' \
    'Usage: zcode-job start [--tool <tool>] <owner/repo> <prompt>' \
    '       zcode-job continue <job-id> <message>' \
    '       zcode-job status|result|cancel <job-id>' \
    '       zcode-job result <job-id> --output FILE  (also writes the output text to FILE)' \
    '       zcode-job live|repos' \
    'start and continue wait up to ZCODE_JOB_WAIT seconds (default 240, range 1..290).' \
    'Set ZCODE_JOB_JSON=1 for the original immediate JSON response.' \
    'tools: zcode (default), opencode, opencode-local, opencode-zai, opencode-qwen, cursor-agent, qwen-code'
  exit 0
fi

fail() {
  if [ "${submitted:-0}" = 1 ] && [ "${ZCODE_JOB_JSON:-0}" != 1 ] && [ -n "${id:-}" ]; then
    printf 'FAIL|%s|%s\n' "$id" "$(printf '%s' "$1" | tr -d '\r\n')"
    exit 1
  fi
  jq -cn --arg error "$1" '{error: $error}'
  exit "${2:-64}"
}

# Mirrors valid_tool in scripts/agent-dispatch.sh. The dispatcher runs on
# another host, so this client cannot read that list at runtime; the bats
# suite fails when the two lists differ.
tool_allowed() {
  case "$1" in
    zcode | opencode | opencode-local | opencode-zai | opencode-qwen | cursor-agent | qwen-code) ;;
    *) return 1 ;;
  esac
}

valid_repo() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$ ]] &&
    [ "${1#*/}" != . ] && [ "${1#*/}" != .. ]
}

valid_allowed_repo() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/\*$ ]] || valid_repo "$1"
}

allowed_repo() {
  local owner=${1%%/*}
  valid_repo "$1" && jq -e --arg repo "${1,,}" --arg owner "${owner,,}" \
    '.allowedRepos | any((ascii_downcase) as $allowed |
      $allowed == $repo or $allowed == ($owner + "/*"))' \
    <<<"$config" >/dev/null
}

valid_text() {
  local control=$'[\001-\010\013-\037\177]'
  [ -n "$1" ] && [ "${#1}" -le 16384 ] && [[ $1 != *$control* ]]
}

# start and continue hand their text to an untrusted agent, so the caller
# must state that it only contains public data.
untrusted_gate() {
  [ "${UNTRUSTED_OK:-}" = public ] ||
    fail "UNTRUSTED_OK=public is required: jobs run untrusted agents and may only receive public data"
}

# Anonymous git read: the environment is cleared, so no inherited git config or
# GIT_DIR can reach the call; credential helpers, askpass, terminal prompts and
# global or system git config are disabled. Only exit 0 (reachable) allows the
# repository. It runs in an empty directory so no repository config is read.
require_public_repo() {
  local probe rc=0
  probe=$(mktemp -d) || fail "repository is not verifiably public: $1"
  (cd "$probe" &&
    env -i PATH="$PATH" GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      git -c credential.helper= ls-remote --exit-code "https://github.com/$1" HEAD >/dev/null 2>&1) || rc=$?
  rmdir "$probe" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "repository is not verifiably public: $1"
}

config_path="${ZCODE_JOB_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/zcode-job/config.json}"
config=$(jq -ces 'select(length == 1) | .[0] | select(type == "object" and
  (.sshHost | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
  (.allowedRepos | type == "array" and length > 0 and all(.[]; type == "string")) and
  (.liveUrl | type == "string" and test("^https://[^\\s]+$")))' \
  "$config_path" 2>/dev/null) || fail "Missing or invalid ZCode client configuration"
while IFS= read -r repo; do
  valid_allowed_repo "$repo" || fail "Invalid approved repository list"
done < <(jq -r '.allowedRepos[]' <<<"$config")

host=$(jq -r '.sshHost' <<<"$config")
verb="${1:-}"
[ $# -gt 0 ] && shift
id=""

request() {
  local rc returned_tool
  if response=$(timeout "${request_timeout:-300}" "$ZCODE_JOB_SSH" -T -n -o BatchMode=yes -o ConnectTimeout=10 \
      -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
      -o ForwardAgent=no -o ClearAllForwardings=yes -o PermitLocalCommand=no \
      -o RemoteCommand=none -o 'SendEnv=-*' -- "$host" "$1"); then
    rc=0
  else
    rc=$?
    if [ "$rc" -eq 124 ] && [ "${submitted:-0}" = 1 ]; then fail timeout 1; fi
    [ -n "$response" ] || fail "Dispatcher SSH request failed" "$rc"
  fi
  response=$(jq -ces 'select(length == 1 and (.[0] | type == "object")) | .[0]' \
    <<<"$response" 2>/dev/null) || fail "Invalid dispatcher JSON" 1
  jq -e --arg id "$id" '(.job | type == "string" and test("^j-[0-9a-f]{16}$")) and
    ($id == "" or .job == $id) and (.tool | type == "string") and
    (.repo | type == "string") and
    (.state | IN("starting", "running", "cancelling", "succeeded", "failed", "cancelled", "timeout")) and
    (.output == null or (.output | type == "string")) and
    (.reason == null or (.reason | type == "string")) and
    (.duration | type == "number" and . >= 0 and floor == .) and
    (.pr | type == "string")' <<<"$response" >/dev/null || fail "Invalid dispatcher result" 1
  returned_tool=$(jq -r '.tool' <<<"$response")
  tool_allowed "$returned_tool" || fail "Dispatcher tool is not supported" 1
  repo=$(jq -r '.repo' <<<"$response")
  allowed_repo "$repo" || fail "Dispatcher repository is not approved" 1
  if [ "$verb" = start ]; then
    [ "$returned_tool" = "$requested_tool" ] ||
      fail "Dispatcher returned a different tool" 1
    [ "${repo,,}" = "${requested_repo,,}" ] ||
      fail "Dispatcher returned a different repository" 1
  fi
  pr=$(jq -r '.pr' <<<"$response")
  if [ -n "$pr" ]; then
    prefix="https://github.com/$repo/pull/"
    [[ ${pr,,} == "${prefix,,}"* && ${pr:${#prefix}} =~ ^[0-9]+$ ]] ||
      fail "Invalid dispatcher PR URL" 1
  fi
  response=$(jq -c '{job, tool, repo, state, pr, duration, runs, reason,
    output: (.output // "")}' <<<"$response")
  if [ "$rc" -ne 0 ]; then
    if [ "${ZCODE_JOB_JSON:-0}" != 1 ] && { [ "$verb" = start ] || [ "$verb" = continue ]; }; then
      id=$(jq -r '.job' <<<"$response")
      submitted=1
      fail "$(jq -r '.reason // "request failed"' <<<"$response")" 1
    fi
    printf '%s\n' "$response"
    exit "$rc"
  fi
}

case "$verb" in
  start)
    requested_tool=zcode
    if [ "${1:-}" = --tool ]; then
      [ $# -ge 2 ] || fail "usage: zcode-job start [--tool <tool>] <owner/repo> <prompt>"
      requested_tool=$2
      shift 2
    fi
    [ $# -eq 2 ] || fail "usage: zcode-job start [--tool <tool>] <owner/repo> <prompt>"
    tool_allowed "$requested_tool" || fail "Unsupported tool"
    allowed_repo "$1" || fail "Repository is not approved for ZCode"
    valid_text "$2" || fail "Invalid prompt"
    requested_repo="$1"
    untrusted_gate
    require_public_repo "$requested_repo"
    request "start $requested_tool $requested_repo $2"
    ;;
  continue | status | result | cancel)
    if [ "$verb" = continue ]; then
      [ $# -eq 2 ] || fail "usage: zcode-job continue <job-id> <message>"
      valid_text "$2" || fail "Invalid continuation message"
      untrusted_gate
    elif [ "$verb" = result ] && [ $# -eq 3 ] && [ "$2" = --output ]; then
      output_path=$3
      [ -n "$output_path" ] || fail "usage: zcode-job result <job-id> [--output FILE]"
      set -- "$1"
    else
      [ $# -eq 1 ] || fail "usage: zcode-job $verb <job-id>"
    fi
    id="$1"
    [[ $id =~ ^j-[0-9a-f]{16}$ ]] || fail "Invalid job id"
    # Validate the existing job's tool and repository before a mutation.
    request "status $id"
    if [ "$verb" = continue ]; then
      require_public_repo "$(jq -r '.repo' <<<"$response")"
      request "continue $id $2"
    fi
    if [ "$verb" = cancel ]; then request "cancel $id"; fi
    if [ "$verb" = result ]; then
      jq -e '.state | IN("succeeded", "failed", "cancelled", "timeout")' \
        <<<"$response" >/dev/null || fail "Job has no terminal result" 1
      response=$(jq -c '. + {result: (["job: " + .job, "tool: " + .tool,
        "repo: " + .repo, "state: " + .state,
        "pr: " + (if .pr == "" then "none" else .pr end),
        "duration: " + (.duration | tostring) + "s",
        "output:\n" + (.output // "") +
          (if .state == "failed" then
            (if (.output // "") == "" or ((.output // "") | endswith("\n"))
             then "" else "\n" end) + "reason: " + (.reason // "")
          else "" end)] | join("\n"))}' <<<"$response")
      # --output FILE: the job's output text alone, for non-interactive readers.
      if [ -n "${output_path:-}" ]; then
        jq -j '.output // ""' <<<"$response" >"$output_path" || fail "Cannot write $output_path" 1
      fi
    fi
    ;;
  live)
    [ $# -eq 0 ] || fail "usage: zcode-job live"
    jq -c '{url: .liveUrl, surface: "zcode-web-server"}' <<<"$config"
    exit 0
    ;;
  repos)
    [ $# -eq 0 ] || fail "usage: zcode-job repos"
    jq -c '{repos: .allowedRepos}' <<<"$config"
    exit 0
    ;;
  *) fail "usage: zcode-job start|continue|status|result|cancel|live|repos" ;;
esac
if { [ "$verb" = start ] || [ "$verb" = continue ]; } && [ "${ZCODE_JOB_JSON:-0}" != 1 ]; then
  id=$(jq -r '.job' <<<"$response")
  submitted=1
  wait_seconds=${ZCODE_JOB_WAIT:-240}
  [[ $wait_seconds =~ ^[0-9]{1,6}$ ]] || wait_seconds=240
  wait_seconds=$((10#$wait_seconds))
  # Each SSH call stays under the dispatcher's 300-second limit.
  ((wait_seconds <= 290)) || wait_seconds=290
  ((wait_seconds >= 1)) || wait_seconds=1
  deadline=$((SECONDS + wait_seconds))
  while :; do
    remaining=$((deadline - SECONDS))
    [ "$remaining" -gt 0 ] || fail timeout 1
    request_timeout=$remaining
    request "status $id"
    state=$(jq -r '.state' <<<"$response")
    case "$state" in
      succeeded)
        pr=$(jq -r '.pr' <<<"$response")
        printf 'DONE|%s|%s\n' "$id" "${pr:-no-pr}"
        exit 0 ;;
      failed | cancelled | timeout)
        reason=$(jq -r '.reason // empty' <<<"$response")
        fail "${reason:-$state}" 1 ;;
    esac
    remaining=$((deadline - SECONDS))
    [ "$remaining" -gt 0 ] || fail timeout 1
    if [ "$remaining" -lt 5 ]; then sleep "$remaining"; else sleep 5; fi
  done
fi
printf '%s\n' "$response"
