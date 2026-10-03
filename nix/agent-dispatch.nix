# The host dispatcher: `agent-dispatch` plus its `dispatch-ssh`
# forced-command entrypoint, in one package.
#
# docker, curl and setsid come from the host; they stay off runtimeInputs so
# the bats suite can stand them in.
{
  lib,
  symlinkJoin,
  writeShellApplication,
  coreutils,
  gnutar,
  jq,
}:

let
  hardeningDefaults = import ./hardening.nix;

  dispatcher = writeShellApplication {
    name = "agent-dispatch";
    runtimeInputs = [
      coreutils
      gnutar
      jq
    ];
    # Task profiles name the bucket fields each tool receives; the same
    # table the image bakes for the entrypoint's profile check.
    text = ''
      AGENT_TASK_PROFILES=${lib.escapeShellArg (builtins.toJSON (import ./task-profiles.nix))}
      AGENT_MEMORY_DEFAULT=${lib.escapeShellArg hardeningDefaults.memory}
      AGENT_CPUS_DEFAULT=${lib.escapeShellArg hardeningDefaults.cpus}
      AGENT_PIDS_LIMIT_DEFAULT=${lib.escapeShellArg hardeningDefaults.pidsLimit}
      AGENT_TIMEOUT_DEFAULT=${lib.escapeShellArg hardeningDefaults.timeout}
    ''
    + builtins.readFile ../scripts/agent-dispatch.sh;
  };

  sshEntrypoint = writeShellApplication {
    name = "dispatch-ssh";
    runtimeInputs = [ dispatcher ];
    text = builtins.readFile ../scripts/dispatch-ssh.sh;
  };
in
symlinkJoin {
  name = "agent-dispatch";
  paths = [
    dispatcher
    sshEntrypoint
  ];
  meta.mainProgram = "agent-dispatch";
}
