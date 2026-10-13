#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'zcode-agent: %s\n' "$1" >&2
  exit "$2"
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  printf '%s\n' \
    'Usage: zcode-agent code|review|triage <owner/repo> -p <prompt-file> -o <out-file>'
  exit 0
fi

[ "$#" -eq 6 ] || fail 'usage: zcode-agent code|review|triage <owner/repo> -p <prompt-file> -o <out-file>' 4
operation="$1"
repo="$2"
[ "$3" = -p ] && [ "$5" = -o ] || fail 'usage: zcode-agent code|review|triage <owner/repo> -p <prompt-file> -o <out-file>' 4
prompt_file="$4"
out_file="$6"
case "$operation" in
  code | review | triage) ;;
  *) fail 'unsupported operation' 4 ;;
esac

if [[ ! $repo =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}$ ]] ||
  [ "${repo#*/}" = . ] || [ "${repo#*/}" = .. ]; then
  fail 'repository is not eligible' 2
fi

owner="${repo%%/*}"
case "${owner,,}" in
  dryvist | jacobpevans | jacobpevans-personal) ;;
  *) fail 'repository is not eligible' 2 ;;
esac

curl_cmd="${ZCODE_AGENT_CURL_CMD:-curl}"
api_url="${ZCODE_AGENT_GITHUB_API_URL:-https://api.github.com}"
metadata=$("$curl_cmd" --fail --silent --show-error --connect-timeout 2 --max-time 5 \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2022-11-28' \
  "${api_url%/}/repos/$repo" 2>/dev/null) || fail 'repository visibility is unavailable' 2
if ! jq -e '.visibility == "public" and .private == false and
  (.default_branch | type == "string" and test("^[A-Za-z0-9._/-]+$"))' \
  <<<"$metadata" >/dev/null; then
  fail 'repository is not eligible' 2
fi
base_branch=$(jq -r '.default_branch' <<<"$metadata")

job_cmd="${ZCODE_AGENT_ZCODE_JOB_CMD:-zcode-job}"
if ! approved=$("$job_cmd" repos 2>/dev/null) || ! jq -e --arg repo "$repo" \
  '.repos | map(ascii_downcase) | index($repo | ascii_downcase) != null' \
  <<<"$approved" >/dev/null; then
  fail 'repository is not eligible' 2
fi

[ -r "$prompt_file" ] || fail 'prompt file is unavailable' 4
prompt=$(cat "$prompt_file") || fail 'prompt file is unavailable' 4
[ -n "$prompt" ] || fail 'prompt is empty' 4
prompt+=$'\n\nAcceptance criteria:\n- Complete the requested scope.\n- Report the checks or findings with concise evidence.'
if [ "$operation" = code ]; then
  prompt+=$'\n- Open a draft pull request targeting the repository default branch and leave it as a draft.'
fi
prompt+=$'\nTarget base branch: '
prompt+="$base_branch"
[ "${#prompt}" -le 16384 ] || fail 'prompt exceeds the job limit' 4

timeout_seconds="${ZCODE_AGENT_TIMEOUT_SECONDS:-1800}"
poll_interval="${ZCODE_AGENT_POLL_INTERVAL_SECONDS:-5}"
[[ $timeout_seconds =~ ^[0-9]{1,5}$ ]] && [ "$timeout_seconds" -gt 0 ] ||
  fail 'invalid job deadline' 4
[[ $poll_interval =~ ^[0-9]{1,2}$ ]] && [ "$poll_interval" -le 60 ] ||
  fail 'invalid poll interval' 4

deadline=$(( $(date +%s) + timeout_seconds ))
job_output=''
remaining() {
  local left
  left=$(( deadline - $(date +%s) ))
  [ "$left" -gt 0 ] || return 1
  printf '%s\n' "$left"
}

quota_failure() {
  jq -er 'if type == "string" then . else tostring end |
    test("quota|429|rate.?limit"; "i")' <<<"$1" >/dev/null 2>&1
}

mark_quota() {
  local marker ttl temp
  marker="${ZAI_QUOTA_MARKER:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-route/zai-quota-until}"
  ttl="${ZCODE_AGENT_QUOTA_TTL_SECONDS:-900}"
  [[ $ttl =~ ^[0-9]{1,5}$ ]] && [ "$ttl" -gt 0 ] || return 1
  umask 077
  mkdir -p "$(dirname "$marker")" || return 1
  temp="${marker}.tmp.$$"
  printf '%s\n' "$(( $(date +%s) + ttl ))" >"$temp" || return 1
  mv -f "$temp" "$marker"
}

call_job() {
  local limit result
  limit=$(remaining) || return 1
  if result=$(timeout "$limit" "$job_cmd" "$@" 2>/dev/null); then
    job_output="$result"
    return 0
  else
    if quota_failure "$result"; then
      mark_quota || return 1
      return 3
    fi
    return 1
  fi
}

mark_output_quota() {
  if quota_failure "$job_output"; then
    mark_quota || fail 'quota state could not be recorded' 4
    fail 'coding plan quota is unavailable' 3
  fi
}

if call_job start "$repo" "$prompt"; then
  :
else
  status=$?
  [ "$status" -eq 3 ] && fail 'coding plan quota is unavailable' 3
  fail 'job start failed' 4
fi
mark_output_quota

job_id=$(jq -er '.job | select(type == "string" and test("^j-[0-9a-f]{16}$"))' \
  <<<"$job_output") || fail 'job start returned an invalid result' 4
jq -e --arg repo "$repo" '.repo | ascii_downcase == ($repo | ascii_downcase)' \
  <<<"$job_output" >/dev/null || fail 'job start returned a different repository' 4

while :; do
  if call_job status "$job_id"; then
    :
  else
    status=$?
    [ "$status" -eq 3 ] && fail 'coding plan quota is unavailable' 3
    "$job_cmd" cancel "$job_id" >/dev/null 2>&1 || true
    fail 'job status failed or deadline expired' 4
  fi
  mark_output_quota
  jq -e --arg job "$job_id" --arg repo "$repo" \
    '.job == $job and (.repo | ascii_downcase == ($repo | ascii_downcase))' \
    <<<"$job_output" >/dev/null || fail 'job status returned a different job' 4
  state=$(jq -er '.state | select(type == "string")' <<<"$job_output") ||
    fail 'job status is invalid' 4
  case "$state" in
    starting | running | cancelling)
      limit=$(remaining) || {
        "$job_cmd" cancel "$job_id" >/dev/null 2>&1 || true
        fail 'job deadline expired' 4
      }
      [ "$poll_interval" -le "$limit" ] || poll_interval="$limit"
      sleep "$poll_interval"
      ;;
    succeeded) break ;;
    failed | cancelled | timeout) fail 'job did not complete successfully' 4 ;;
    *) fail 'job returned an unknown state' 4 ;;
  esac
done

if call_job result "$job_id"; then
  :
else
  status=$?
  [ "$status" -eq 3 ] && fail 'coding plan quota is unavailable' 3
  fail 'job result failed' 4
fi
mark_output_quota
jq -e --arg job "$job_id" --arg repo "$repo" \
  '.job == $job and (.repo | ascii_downcase == ($repo | ascii_downcase)) and
   .state == "succeeded" and (.result | type == "string")' \
  <<<"$job_output" >/dev/null || fail 'job result is invalid' 4

out_tmp="${out_file}.tmp.$$"
trap 'rm -f "$out_tmp"' EXIT
printf '%s\n' "$job_output" >"$out_tmp" || fail 'result could not be written' 4
mv -f "$out_tmp" "$out_file" || fail 'result could not be written' 4
