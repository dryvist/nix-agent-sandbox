# Egress allowlist for agent containers.
#
# Single source of truth for every enforcement point: the (phase 2)
# allowlisting CONNECT proxy package, the docker-host nftables rules
# (ansible-proxmox-apps), and docs.jacobpevans.com/autonomous-agents.
# Agent containers get no other route out.
{
  # Model APIs
  modelApis = [
    "api.anthropic.com"
    "api.openai.com"
    "chatgpt.com" # Codex subscription auth backend
    "generativelanguage.googleapis.com"
    "cloudcode-pa.googleapis.com" # Gemini CLI OAuth path
  ];

  # Source control + artifacts
  github = [
    "github.com"
    "api.github.com"
    "objects.githubusercontent.com"
    "raw.githubusercontent.com"
    "ghcr.io"
    "pkg-containers.githubusercontent.com" # ghcr.io blob backend
  ];

  # Nix substituters for per-repo `nix develop` toolchains
  nix = [
    "cache.nixos.org"
    "channels.nixos.org"
    "install.determinate.systems"
  ];

  # Internal services agents may need (kept empty until a run requires one;
  # additions are deliberate, reviewed changes).
  internal = [ ];
}
