# The `dispatch-ssh` forced-command entrypoint (wrapped by writeShellApplication).
#
# Install it as the `command=` of an authorized_keys entry. It reads
# SSH_ORIGINAL_COMMAND, accepts only these six verbs, and hands each word to
# `agent-dispatch` as its own argument:
#
#   start [--interactive] <tool> <owner/repo> <prompt...>
#   tty <tool> <owner/repo>        (only with a terminal: ssh -t)
#   continue <job-id> <message...>
#   status <job-id>
#   cancel <job-id>
#   refresh
#
# The prompt or message is the rest of the line after the fixed words,
# passed verbatim as one argument. No shell ever evaluates the line, and
# agent-dispatch validates every value. Anything else exits 64.

export LC_ALL=C
line="${SSH_ORIGINAL_COMMAND:-}"

refuse() {
  echo "dispatch-ssh: refused" >&2
  exit 64
}

# Drop leading whitespace from $line.
trim() {
  line="${line#"${line%%[![:space:]]*}"}"
}

# Move the next whitespace-delimited word of $line into $word.
pop() {
  trim
  word="${line%%[[:space:]]*}"
  line="${line#"$word"}"
}

pop
verb="$word"
case "$verb" in
  start)
    flags=()
    pop
    if [ "$word" = --interactive ]; then
      flags=(--interactive)
      pop
    fi
    # A flag in the tool position (start --tty ...) would bypass the
    # terminal check below.
    case "$word" in -*) refuse ;; esac
    tool="$word"
    pop
    repo="$word"
    trim
    exec agent-dispatch start "${flags[@]}" "$tool" "$repo" "$line"
    ;;
  tty)
    [ -t 0 ] && [ -t 1 ] || refuse
    pop
    tool="$word"
    pop
    repo="$word"
    trim
    [ -z "$line" ] || refuse
    exec agent-dispatch start --tty "$tool" "$repo"
    ;;
  continue)
    pop
    id="$word"
    trim
    exec agent-dispatch continue "$id" "$line"
    ;;
  status | cancel)
    pop
    id="$word"
    trim
    [ -z "$line" ] || refuse
    exec agent-dispatch "$verb" "$id"
    ;;
  refresh)
    trim
    [ -z "$line" ] || refuse
    exec agent-dispatch refresh
    ;;
  *) refuse ;;
esac
