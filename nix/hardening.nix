# Docker resource ceilings + wall-clock timeout defaults for autonomous runs,
# shared by `agent` and `agent-dispatch`. Each is env-overridable at call time
# (AGENT_MEMORY / AGENT_CPUS / AGENT_PIDS_LIMIT / AGENT_TIMEOUT); the scripts
# read AGENT_*:-AGENT_*_DEFAULT.
{
  memory = "8g";
  cpus = "4";
  pidsLimit = "512";
  timeout = "3600"; # seconds
}
