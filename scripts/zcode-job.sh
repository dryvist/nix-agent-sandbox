export LC_ALL=C

fail() {
  jq -cn --arg error "$1" '{error: $error}'
  exit "${2:-64}"
}

valid_repo() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$ ]] &&
    [ "${1#*/}" != . ] && [ "${1#*/}" != .. ]
}

allowed_repo() {
  valid_repo "$1" && jq -e --arg repo "$1" \
    '.allowedRepos | map(ascii_downcase) | index($repo | ascii_downcase) != null' \
    <<<"$config" >/dev/null
}

valid_text() {
  local control=$'[\001-\010\013-\037\177]'
  [ -n "$1" ] && [ "${#1}" -le 16384 ] && [[ $1 != *$control* ]]
}

config_path="${ZCODE_JOB_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/zcode-job/config.json}"
config=$(jq -ces 'select(length == 1) | .[0] | select(type == "object" and
  (.sshHost | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
  (.allowedRepos | type == "array" and length > 0 and all(.[]; type == "string")) and
  (.liveUrl | type == "string" and test("^https://[^\\s]+$")))' \
  "$config_path" 2>/dev/null) || fail "Missing or invalid ZCode client configuration"
while IFS= read -r repo; do
  valid_repo "$repo" || fail "Invalid approved repository list"
done < <(jq -r '.allowedRepos[]' <<<"$config")

host=$(jq -r '.sshHost' <<<"$config")
verb="${1:-}"
[ $# -gt 0 ] && shift
id=""

request() {
  local rc
  if response=$(timeout 300 "$ZCODE_JOB_SSH" -T -n -o BatchMode=yes -o ConnectTimeout=10 \
      -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
      -o ForwardAgent=no -o ClearAllForwardings=yes -o PermitLocalCommand=no \
      -o RemoteCommand=none -o 'SendEnv=-*' -- "$host" "$1"); then
    rc=0
  else
    rc=$?
    [ -n "$response" ] || fail "Dispatcher SSH request failed" "$rc"
  fi
  response=$(jq -ces 'select(length == 1 and (.[0] | type == "object")) | .[0]' \
    <<<"$response" 2>/dev/null) || fail "Invalid dispatcher JSON" 1
  jq -e --arg id "$id" '(.job | type == "string" and test("^j-[0-9a-f]{16}$")) and
    ($id == "" or .job == $id) and .tool == "zcode" and
    (.repo | type == "string") and
    (.state | IN("starting", "running", "cancelling", "succeeded", "failed", "cancelled", "timeout")) and
    (.duration | type == "number" and . >= 0 and floor == .) and
    (.pr | type == "string")' <<<"$response" >/dev/null || fail "Invalid dispatcher result" 1
  repo=$(jq -r '.repo' <<<"$response")
  allowed_repo "$repo" || fail "Dispatcher repository is not approved" 1
  if [ "$verb" = start ]; then
    [ "${repo,,}" = "${requested_repo,,}" ] ||
      fail "Dispatcher returned a different repository" 1
  fi
  pr=$(jq -r '.pr' <<<"$response")
  if [ -n "$pr" ]; then
    prefix="https://github.com/$repo/pull/"
    [[ ${pr,,} == "${prefix,,}"* && ${pr:${#prefix}} =~ ^[0-9]+$ ]] ||
      fail "Invalid dispatcher PR URL" 1
  fi
  response=$(jq -c '{job, tool, repo, state, pr, duration, runs, reason}' <<<"$response")
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$response"
    exit "$rc"
  fi
}

case "$verb" in
  start)
    [ $# -eq 2 ] || fail "usage: zcode-job start <owner/repo> <prompt>"
    allowed_repo "$1" || fail "Repository is not approved for ZCode"
    valid_text "$2" || fail "Invalid prompt"
    requested_repo="$1"
    request "start zcode $requested_repo $2"
    ;;
  continue | status | result | cancel)
    if [ "$verb" = continue ]; then
      [ $# -eq 2 ] || fail "usage: zcode-job continue <job-id> <message>"
      valid_text "$2" || fail "Invalid continuation message"
    else
      [ $# -eq 1 ] || fail "usage: zcode-job $verb <job-id>"
    fi
    id="$1"
    [[ $id =~ ^j-[0-9a-f]{16}$ ]] || fail "Invalid job id"
    # Validate the existing job's tool and repository before a mutation.
    request "status $id"
    if [ "$verb" = continue ]; then request "continue $id $2"; fi
    if [ "$verb" = cancel ]; then request "cancel $id"; fi
    if [ "$verb" = result ]; then
      jq -e '.state | IN("succeeded", "failed", "cancelled", "timeout")' \
        <<<"$response" >/dev/null || fail "Job has no terminal result" 1
      response=$(jq -c '. + {result: (["job: " + .job, "tool: " + .tool,
        "repo: " + .repo, "state: " + .state,
        "pr: " + (if .pr == "" then "none" else .pr end),
        "duration: " + (.duration | tostring) + "s"] | join("\n"))}' <<<"$response")
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
printf '%s\n' "$response"
