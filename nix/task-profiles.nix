# Task profiles: the pre-defined group of secrets a run is granted, selected
# at launch with `agent run --profile <name>`. Baked into the image as
# /home/agent/.agent-profiles.json and injected into the launcher.
#
# The launcher forwards each named variable from the caller's environment
# into the container, and refuses to start when one is unset. Nothing else from the caller's environment is
# forwarded beyond the fixed credential list in agent-cli.sh.
#
# GitHub write access is NOT part of a profile — `--repo` uses GH_TOKEN, or
# the token printed by AGENT_GH_TOKEN_CMD (see agent-cli.sh).
#
# Shape per profile:
#   env  list of environment variable names the run requires.
{
  # Estate-context reads only. No secrets exported; model keys come from the
  # caller's environment exactly as before.
  readonly = {
    env = [ ];
  };

  # Standard autonomous dev run: requires a model API key.
  dev = {
    env = [ "ANTHROPIC_API_KEY" ];
  };
}
