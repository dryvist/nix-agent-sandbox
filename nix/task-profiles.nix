# Task profiles: the pre-defined environment a run is granted, selected
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
#   routerKeyField  optional bucket field delivered as AGENT_ROUTER_KEY.
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

  # agent-dispatch tools: each job uses the profile named after its tool.
  # The dispatcher copies each named field of its secret bucket into the
  # container under the same name. Routed CLIs receive only the router URL/key.
  zai = {
    env = [ "ZAI_SUBSCRIPTION_KEY" ];
  };
  zcode = {
    env = [ ];
    routerKeyField = "zcode_router_key";
  };
  opencode = {
    env = [ ];
    routerKeyField = "opencode_router_key";
  };
  cursor-agent = {
    env = [ ];
    routerKeyField = "cursor_router_key";
  };
  zcode-web = {
    env = [
      "ZAI_SUBSCRIPTION_KEY"
      "AGENT_WEB_TOKEN"
    ];
  };
}
