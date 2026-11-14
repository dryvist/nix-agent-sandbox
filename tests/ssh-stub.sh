#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$STUB_DIR/ssh-argv"
printf '%s\n' "${!#}" >>"$STUB_DIR/ssh-commands"
fail_on="${STUB_SSH_FAIL_ON:-}"
if [ "${STUB_SSH_EXIT:-0}" -ne 0 ] && { [ -z "$fail_on" ] || [[ ${!#} == "$fail_on"* ]]; }; then
  if [ -e "$STUB_DIR/ssh-stderr" ]; then cat "$STUB_DIR/ssh-stderr" >&2; fi
  if [ "${STUB_RESPONSE_ON_ERROR:-0}" = 1 ]; then cat "$STUB_DIR/response.json"; fi
  exit "$STUB_SSH_EXIT"
fi
if [[ ${!#} == cancel* ]]; then
  jq '.state = "cancelling"' "$STUB_DIR/response.json"
else
  cat "$STUB_DIR/response.json"
fi
