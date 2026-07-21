# Repo groups: named fan-out sets for `agent sweep --group <name>`.
#
# One repo per container run stays the law — a group is purely launcher-side
# fan-out (agent-cli.sh `sweep`), never a single multi-repo run. Each member
# is cloned, branched, and PR'd in its own disposable container with its own
# repo-scoped GitHub write token, exactly like `agent run --repo`.
#
# Baked into the `agent` CLI as JSON by agent-cli.nix (single source of
# truth) and exported as `lib.repoGroups` for docs and downstream consumers.
#
# Shape per group:
#   profile  task profile (see task-profiles.nix) every run in the group uses.
#   repos    list of { name, branch }: the repo (owner dryvist) and the base
#            branch the container clones/PRs against. `branch` is each repo's
#            live GitHub default branch — the branch `gh repo clone` checks
#            out — recorded here for the sweep summary and to document intent.
#
# Repo lists derive from ${GIT_HOME}/REPOS.md; branches verified live at
# authoring time.
{
  # Nix ecosystem — every repo is git-flow (develop is the integration branch).
  nix = {
    profile = "dev";
    repos = [
      {
        name = "nix-darwin";
        branch = "develop";
      }
      {
        name = "nix-ai";
        branch = "develop";
      }
      {
        name = "nix-home";
        branch = "develop";
      }
      {
        name = "nix-devenv";
        branch = "develop";
      }
      {
        name = "nix-claude-code";
        branch = "develop";
      }
      {
        name = "nix-pxe-bootstrap";
        branch = "develop";
      }
    ];
  };

  # Homelab infrastructure-as-code (Proxmox + UniFi + Ansible).
  # tofu-unifi is the one private member; every other repo here is public.
  # It is included because it is core homelab IaC and the github-write mint
  # already handles private clones — flagged for reviewer to drop if the
  # public-only convention should win.
  homelab-iac = {
    profile = "dev";
    repos = [
      {
        name = "tofu-proxmox";
        branch = "develop";
      }
      {
        name = "tofu-unifi";
        branch = "main";
      }
      {
        name = "ansible-proxmox";
        branch = "develop";
      }
      {
        name = "ansible-proxmox-apps";
        branch = "develop";
      }
    ];
  };

  # AI tooling config: the plugins marketplace + the nix-ai home-manager module.
  ai = {
    profile = "dev";
    repos = [
      {
        name = "claude-code-plugins";
        branch = "main";
      }
      {
        name = "nix-ai";
        branch = "develop";
      }
    ];
  };

  # Documentation sites.
  docs = {
    profile = "dev";
    repos = [
      {
        name = "docs";
        branch = "main";
      }
      {
        name = "docs-starlight";
        branch = "main";
      }
    ];
  };
}
