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
#   routerKeyField  host-side value used when scanning published changes.
#   sandboxRouterKeyField  container leaf field exported as AGENT_ROUTER_KEY.
#   ttyLogin  in a terminal session (agent-dispatch --tty) the user signs in
#             to the tool by hand, so neither router key nor env is delivered.
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
  # The dispatcher resolves each named value from its configured store and
  # copies it into the container. Routed CLIs receive only their router URL/key.
  zai = {
    env = [ "ZAI_SUBSCRIPTION_KEY" ];
  };
  qwen = {
    env = [
      "AGENT_ROUTER_BASE_URL"
      "AGENT_ROUTER_KEY"
      "AGENT_MODEL"
    ];
  };
  zcode = {
    env = [ ];
    routerKeyField = "ZCODE_ROUTER_KEY";
    sandboxRouterKeyField = "router_key";
    ttyLogin = true;
  };
  opencode = {
    env = [ ];
    routerKeyField = "OPENCODE_ROUTER_KEY";
    sandboxRouterKeyField = "router_key";
    ttyLogin = true;
  };
  opencode-local = {
    env = [ ];
    routerKeyField = "OPENCODE_ROUTER_KEY";
    sandboxRouterKeyField = "router_key";
  };
  opencode-zai = {
    env = [ "ZAI_SUBSCRIPTION_KEY" ];
  };
  # Runs the prompt as a bash command; fix jobs only, no model credential.
  shell = {
    env = [ ];
  };
  # Cursor has no router endpoint or batch credential. A terminal session
  # signs in by hand.
  cursor-agent = {
    env = [ ];
    ttyLogin = true;
  };
  # Qwen Code: batch only. The entrypoint runs it on the router's `medium`
  # capability; the caller does not choose the model.
  qwen-code = {
    env = [ ];
    routerKeyField = "QWEN_CODE_ROUTER_KEY";
    sandboxRouterKeyField = "router_key";
  };
  zcode-web = {
    env = [
      "ZAI_SUBSCRIPTION_KEY"
      "AGENT_WEB_TOKEN"
    ];
  };
}
