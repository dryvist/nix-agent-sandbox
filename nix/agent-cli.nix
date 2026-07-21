# The `agent` dispatch CLI.
#
# Thin wrapper that launches the agent image with Apple `container`
# (preferred on macOS) or Docker. Replaces the gh-claude-* launcher zoo:
# autonomy comes from the image, not from how the host shell was blessed.
{ lib, writeShellApplication }:

writeShellApplication {
  name = "agent";
  # The repo-group table (repo-groups.nix, also exported as lib.repoGroups)
  # is the single source of truth; inject it as JSON so `agent sweep` reads
  # the same data with no second copy and no runtime `nix eval`.
  text = ''
    AGENT_REPO_GROUPS=${lib.escapeShellArg (builtins.toJSON (import ./repo-groups.nix))}
  ''
  + builtins.readFile ../scripts/agent-cli.sh;
}
