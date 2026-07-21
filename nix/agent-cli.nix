# The `agent` dispatch CLI.
#
# Thin wrapper that launches the agent image with Apple `container`
# (preferred on macOS) or Docker. Replaces the gh-claude-* launcher zoo:
# autonomy comes from the image, not from how the host shell was blessed.
{ lib, writeShellApplication }:

let
  # Docker resource ceilings + wall-clock timeout defaults for autonomous
  # runs. Each is env-overridable at call time (AGENT_MEMORY / AGENT_CPUS /
  # AGENT_PIDS_LIMIT / AGENT_TIMEOUT); the script reads AGENT_*:-AGENT_*_DEFAULT.
  hardeningDefaults = {
    memory = "8g";
    cpus = "4";
    pidsLimit = "512";
    timeout = "3600"; # seconds
  };
in
writeShellApplication {
  name = "agent";
  # The repo-group table (repo-groups.nix, also exported as lib.repoGroups)
  # is the single source of truth; inject it as JSON so `agent sweep` reads
  # the same data with no second copy and no runtime `nix eval`. The
  # hardening defaults are injected the same way (baked here, env-overridable).
  text = ''
    AGENT_REPO_GROUPS=${lib.escapeShellArg (builtins.toJSON (import ./repo-groups.nix))}
    AGENT_MEMORY_DEFAULT=${lib.escapeShellArg hardeningDefaults.memory}
    AGENT_CPUS_DEFAULT=${lib.escapeShellArg hardeningDefaults.cpus}
    AGENT_PIDS_LIMIT_DEFAULT=${lib.escapeShellArg hardeningDefaults.pidsLimit}
    AGENT_TIMEOUT_DEFAULT=${lib.escapeShellArg hardeningDefaults.timeout}
  ''
  + builtins.readFile ../scripts/agent-cli.sh;
}
