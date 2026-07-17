# Task profiles: the pre-defined group of secrets (and GitHub scope) a run is
# granted, selected at launch with `agent run --profile <name>`. Baked into the
# image as /home/agent/.agent-profiles.json and consumed by the entrypoint's
# OpenBao block; which profiles a given AppRole can actually satisfy is decided
# server-side by that role's OpenBao policies (ai-readonly / ai-apply-<svc>,
# see ansible-proxmox-apps roles/openbao).
#
# Shape per profile:
#   kv                  list of { path, field, env }: KV v2 path under the
#                       `secret/` mount (no data/ segment), the field to read,
#                       and the environment variable it becomes.
#   githubPermissionSet OpenBao github/ engine permission set to mint the
#                       per-run GH_TOKEN from ("" = no mint; the run uses a
#                       caller-supplied GH_TOKEN or none).
{
  # Estate-context reads only. No secrets exported, no GitHub token minted;
  # model keys come from the caller's environment exactly as before.
  readonly = {
    kv = [ ];
    githubPermissionSet = "";
  };

  # Standard autonomous dev run: model key from the paid-SaaS provider area
  # and a per-run repo-scoped GitHub App installation token (<=1h).
  dev = {
    kv = [
      {
        path = "ai/saas/anthropic";
        field = "ANTHROPIC_API_KEY";
        env = "ANTHROPIC_API_KEY";
      }
    ];
    githubPermissionSet = "dryvist-full-automation";
  };
}
