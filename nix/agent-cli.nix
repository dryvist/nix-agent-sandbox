# The `agent` dispatch CLI.
#
# Thin wrapper that launches the agent image with Apple `container`
# (preferred on macOS) or Docker. Replaces the gh-claude-* launcher zoo:
# autonomy comes from the image, not from how the host shell was blessed.
{ writeShellApplication }:

writeShellApplication {
  name = "agent";
  text = builtins.readFile ../scripts/agent-cli.sh;
}
