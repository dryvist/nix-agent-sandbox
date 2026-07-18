# Task profiles: the pre-defined group of secrets a run is granted, selected
# at launch with `agent run --profile <name>`. Baked into the image as
# /home/agent/.agent-profiles.json and consumed by the entrypoint's OpenBao
# block; which profiles a given AppRole can actually satisfy is decided
# server-side by that role's OpenBao policies (ai-readonly / ai-apply-<svc>,
# see ansible-proxmox-apps roles/openbao).
#
# GitHub write access is NOT part of a profile — it's minted by the launcher
# (agent-cli.sh) via the workstation-only `github-write` OpenBao identity
# whenever `--repo` is given, independent of which profile is selected.
#
# Shape per profile:
#   kv   list of { path, field, env }: KV v2 path under the `secret/` mount
#        (no data/ segment), the field to read, and the environment variable
#        it becomes.
{
  # Estate-context reads only. No secrets exported; model keys come from the
  # caller's environment exactly as before.
  readonly = {
    kv = [ ];
  };

  # Standard autonomous dev run: model key from the paid-SaaS provider area.
  dev = {
    kv = [
      {
        path = "ai/saas/anthropic";
        field = "ANTHROPIC_API_KEY";
        env = "ANTHROPIC_API_KEY";
      }
    ];
  };
}
