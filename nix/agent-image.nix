# The agent runtime image.
#
# One OCI image, two consumers: Apple `container` on macOS (aarch64-linux)
# and Docker on the Proxmox docker-host VM (x86_64-linux). Runs as the
# non-root `agent` user (uid 1000) — Claude Code hard-rejects bypass mode
# as root, and nothing in here needs root. No sudo in the image.
#
# The autonomous tool configs are baked from dryvist/nix-ai's
# lib.renderAutonomous.files — the only place they are ever rendered.
# Per-repo toolchains are NOT baked in; the target repo's own flake
# devShell supplies them via `nix develop` (nix is in the image).
{
  lib,
  dockerTools,
  runCommand,
  writeShellApplication,
  writeTextDir,
  bashInteractive,
  cacert,
  claude-code,
  codex,
  coreutils,
  curl,
  gemini-cli,
  gh,
  git,
  gnugrep,
  jq,
  nix,
  ripgrep,
  renderAutonomous,
}:

let
  homeDir = "/home/agent";

  toolPackages = [
    claude-code
    codex
    gemini-cli
  ];

  basePackages = [
    bashInteractive
    cacert
    coreutils
    curl
    gh
    git
    gnugrep
    jq
    nix
    ripgrep
  ];

  entrypoint = writeShellApplication {
    name = "agent-entrypoint";
    runtimeInputs = toolPackages ++ basePackages;
    text = builtins.readFile ../scripts/entrypoint.sh;
  };

  # Bake every autonomous config from the single nix-ai source. The attrset
  # is path -> contents, so a new tool config added upstream lands here
  # without changes.
  configFiles = lib.mapAttrsToList (
    path: contents: writeTextDir "${lib.removePrefix "/" homeDir}/${path}" contents
  ) renderAutonomous.files;

  etcFiles = runCommand "agent-etc" { } ''
    mkdir -p $out/etc
    cat > $out/etc/passwd <<EOF
    root:x:0:0:root:/root:${bashInteractive}/bin/bash
    agent:x:1000:1000:agent:${homeDir}:${bashInteractive}/bin/bash
    nobody:x:65534:65534:nobody:/nonexistent:/bin/false
    EOF
    cat > $out/etc/group <<EOF
    root:x:0:
    agent:x:1000:
    nobody:x:65534:
    EOF
    echo "hosts: files dns" > $out/etc/nsswitch.conf
  '';
in
dockerTools.streamLayeredImage {
  name = "ghcr.io/dryvist/nix-agent-sandbox/agent";
  tag = "latest";

  contents = toolPackages ++ basePackages ++ configFiles ++ [ etcFiles ];

  fakeRootCommands = ''
    mkdir -p ./home/agent/work ./tmp
    chown -R 1000:1000 ./home/agent
    chmod 1777 ./tmp
  '';

  config = {
    User = "1000:1000";
    WorkingDir = "${homeDir}/work";
    Entrypoint = [ "${entrypoint}/bin/agent-entrypoint" ];
    Env = [
      "HOME=${homeDir}"
      "USER=agent"
      # The refusal guard in the entrypoint keys off this; it exists only
      # inside this image, never on a host.
      "AGENT_SANDBOX=1"
      "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
      "NIX_SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
      "GIT_SSL_CAINFO=${cacert}/etc/ssl/certs/ca-bundle.crt"
      "PATH=/bin:/usr/bin"
    ];
  };
}
