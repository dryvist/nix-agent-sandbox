# Included before agent-dispatch.sh by nix/agent-dispatch.nix.
write_result_tail() {
  local rdir=$1 tail_file="$1/result-tail" size boundary
  : >"$rdir/result.txt"
  if [ ! -f "$rdir/log" ]; then
    chmod 600 "$rdir/result.txt"
    return
  fi
  tail -n 60 "$rdir/log" >"$tail_file" || : >"$tail_file"
  chmod 600 "$tail_file"
  size=$(wc -c <"$tail_file")
  if ((size > 16384)); then
    boundary=$(tail -c 16385 "$tail_file" | head -c 1 | od -An -t x1 | tr -d '[:space:]')
    if [ "$boundary" = 0a ]; then
      tail -c 16384 "$tail_file" | redact_log_values >"$rdir/result.txt"
    else
      tail -c 16384 "$tail_file" | sed '1d' | redact_log_values >"$rdir/result.txt"
    fi
  else
    redact_log_values <"$tail_file" >"$rdir/result.txt"
  fi
  rm -f "$tail_file"
  chmod 600 "$rdir/result.txt"
}
