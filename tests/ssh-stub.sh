#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$STUB_DIR/ssh-argv"
printf '%s\n' "${!#}" >>"$STUB_DIR/ssh-commands"
if [ "${STUB_SSH_EXIT:-0}" -ne 0 ]; then
  if [ "${STUB_RESPONSE_ON_ERROR:-0}" = 1 ]; then cat "$STUB_DIR/response.json"; fi
  exit "$STUB_SSH_EXIT"
fi
if [[ ${!#} == cancel* ]]; then
  jq '.state = "cancelling"' "$STUB_DIR/response.json"
else
  cat "$STUB_DIR/response.json"
fi
