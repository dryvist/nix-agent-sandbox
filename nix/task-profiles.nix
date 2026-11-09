# Task profiles: the pre-defined environment a run is granted, selected
# at launch with `agent run --profile <name>`. Baked into the image as
# /home/agent/.agent-profiles.json and injected into the launcher.
#
# The launcher forwards each named variable from the caller's environment
# into the container, and refuses to start when one is unset. Nothing else from the caller's environment is
# forwarded beyond the fixed credential list in agent-cli.sh.
#
# GitHub write access is NOT part of a profile. Local runs are retired in
# favor of the dispatcher.
#
# Shape per profile:
#   env  list of environment variable names the run requires.
#   batchCapable  the dispatcher may run the profile as a batch job (no terminal).
#   routerKeyField  host-side value used when scanning published changes.
#   sandboxRouterKeyField  container leaf field exported as AGENT_ROUTER_KEY.
#   trackerAccess  whether the job receives Vikunja and Zammad configuration
#                  (defaults to true when omitted).
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
    batchCapable = true;
    env = [ "ANTHROPIC_API_KEY" ];
  };

  # agent-dispatch tools: each job uses the profile named after its tool.
  # The dispatcher resolves each named value from its configured store and
  # copies it into the container. Routed CLIs receive only their router URL/key.
  zai = {
    batchCapable = true;
    env = [ "ZAI_SUBSCRIPTION_KEY" ];
  };
  qwen = {
    batchCapable = true;
    env = [
      "AGENT_ROUTER_BASE_URL"
      "AGENT_ROUTER_KEY"
      "AGENT_MODEL"
    ];
  };
  # zcode and opencode run under their own OpenBao roles, which cannot read
  # tracker tokens, so neither profile grants tracker access.
  zcode = {
    batchCapable = true;
    env = [ ];
    trackerAccess = false;
    ttyLogin = true;
  };
  opencode = {
    batchCapable = true;
    env = [ ];
    routerKeyField = "OPENCODE_ROUTER_KEY";
    sandboxRouterKeyField = "sandbox_agent_router_llm_router_key";
    trackerAccess = false;
    ttyLogin = true;
  };
  opencode-local = {
    batchCapable = true;
    env = [ ];
    routerKeyField = "OPENCODE_LOCAL_ROUTER_KEY";
    sandboxRouterKeyField = "sandbox_agent_local_router_llm_router_key";
    trackerAccess = false;
  };
  opencode-zai = {
    batchCapable = true;
    env = [
      "ZAI_SUBSCRIPTION_KEY"
      "ZAI_MODEL"
    ];
  };
  # Runs the prompt as a bash command; fix jobs only, no model credential.
  shell = {
    env = [ ];
  };
  # Cursor batch runs use the API key; terminal sessions sign in by
  # hand.
  cursor-agent = {
    batchCapable = true;
    env = [ "CURSOR_API_KEY" ];
    ttyLogin = true;
  };
  # Qwen Code: batch only. The entrypoint runs it on the router's `medium`
  # capability; the caller does not choose the model.
  qwen-code = {
    batchCapable = true;
    env = [ ];
    routerKeyField = "QWEN_CODE_ROUTER_KEY";
    sandboxRouterKeyField = "sandbox_agent_router_llm_router_key";
  };
  zcode-web = {
    batchCapable = true;
    env = [
      "ZAI_SUBSCRIPTION_KEY"
      "AGENT_WEB_TOKEN"
    ];
  };
}
