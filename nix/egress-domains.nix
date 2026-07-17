# Egress allowlist for agent containers.
#
# Single source of truth for every enforcement point: the docker-host
# allowlisting CONNECT proxy (ansible-proxmox-apps roles/agent_sandbox —
# regenerate its committed copy with
# `nix eval .#lib.egressDomains --json`) and
# docs.jacobpevans.com/autonomous-agents. Agent containers get no other
# route out. Internal FQDNs (OpenBao's ingress route) are appended on the
# ansible side from the inventory domain — never as literals here.
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
