# The `agent` dispatch CLI.
#
# Thin wrapper that launches the agent image with Apple `container`
# (preferred on macOS) or Docker. Replaces the gh-claude-* launcher zoo:
# autonomy comes from the image, not from how the host shell was blessed.
{ lib, writeShellApplication }:

let
  hardeningDefaults = import ./hardening.nix;
in
writeShellApplication {
  name = "agent";
  # The hardening defaults are baked in here; each is overridable per run.
  text = ''
    AGENT_TASK_PROFILES=${lib.escapeShellArg (builtins.toJSON (import ./task-profiles.nix))}
    AGENT_MEMORY_DEFAULT=${lib.escapeShellArg hardeningDefaults.memory}
    AGENT_CPUS_DEFAULT=${lib.escapeShellArg hardeningDefaults.cpus}
    AGENT_PIDS_LIMIT_DEFAULT=${lib.escapeShellArg hardeningDefaults.pidsLimit}
    AGENT_TIMEOUT_DEFAULT=${lib.escapeShellArg hardeningDefaults.timeout}
  ''
  + builtins.readFile ../scripts/agent-cli.sh;
}
