# The agent runtime image.
#
# One OCI image, two consumers: Apple `container` on macOS (aarch64-linux)
# and Docker on a remote Linux host (x86_64-linux). Runs as the
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
  cursorAgent,
  gh,
  git,
  gitleaks,
  gnugrep,
  jq,
  nix,
  nodejs_24,
  openbao,
  opencode,
  qwenCode,
  ripgrep,
  vikunjaMcp,
  zammadMcp,
  renderAutonomous,
  zcodeWeb,
}:

let
  homeDir = "/home/agent";

  zcodeWebSupervisor = writeShellApplication {
    name = "zcode-web-supervisor";
    runtimeInputs = [
      nodejs_24
      zcodeWeb
    ];
    text = ''
      export ZCODE_WEB_CLIENT=${lib.escapeShellArg "${zcodeWeb}/share/zcode-web/client.mjs"}
      exec node ${../scripts/zcode-web-supervisor.mjs}
    '';
  };

  zcodeWebTask = writeShellApplication {
    name = "zcode-web-task";
    runtimeInputs = [
      nodejs_24
      zcodeWeb
    ];
    text = ''
      export ZCODE_WEB_CLIENT=${lib.escapeShellArg "${zcodeWeb}/share/zcode-web/client.mjs"}
      exec node ${../scripts/zcode-web-task.mjs} "$@"
    '';
  };

  zammadMcpWrapper = writeShellApplication {
    name = "sandbox-zammad-mcp";
    runtimeInputs = [
      coreutils
      zammadMcp
    ];
    text = builtins.readFile ../scripts/zammad-mcp.sh;
  };

  toolPackages = [
    claude-code
    codex
    zcodeWeb
    zcodeWebSupervisor
    zcodeWebTask
    vikunjaMcp
    zammadMcpWrapper
    opencode
    cursorAgent
    qwenCode
  ];

  basePackages = [
    bashInteractive
    cacert
    coreutils
    curl
    gh
    git
    gitleaks # pre-push staged-diff secret scan in the entrypoint
    gnugrep
    jq
    nix
    openbao
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
  autonomousFiles = builtins.removeAttrs renderAutonomous.files [
    ".config/opencode/opencode.json"
  ];

  configFiles = lib.mapAttrsToList (
    path: contents: writeTextDir "${lib.removePrefix "/" homeDir}/${path}" contents
  ) autonomousFiles;

  # Task profiles (the environment variables each profile requires),
  # checked by the entrypoint.
  profilesFile = writeTextDir "${lib.removePrefix "/" homeDir}/.agent-profiles.json" (
    builtins.toJSON (import ./task-profiles.nix)
  );

  baoAgentFiles = lib.mapAttrsToList (path: contents: writeTextDir path contents) {
    "etc/openbao-agent/read.hcl" =
      lib.replaceStrings [ "@AGENT_ENTRYPOINT@" ] [ "${entrypoint}/bin/agent-entrypoint" ]
        (builtins.readFile ../templates/bao-agent/read.hcl);
    "etc/openbao-agent/write.hcl" =
      lib.replaceStrings [ "@AGENT_ENTRYPOINT@" ] [ "${entrypoint}/bin/agent-entrypoint" ]
        (builtins.readFile ../templates/bao-agent/write.hcl);
    "etc/openbao-agent/read-public.hcl" =
      lib.replaceStrings [ "@AGENT_ENTRYPOINT@" ] [ "${entrypoint}/bin/agent-entrypoint" ]
        (builtins.readFile ../templates/bao-agent/read-public.hcl);
    "etc/openbao-agent/write-public.hcl" =
      lib.replaceStrings [ "@AGENT_ENTRYPOINT@" ] [ "${entrypoint}/bin/agent-entrypoint" ]
        (builtins.readFile ../templates/bao-agent/write-public.hcl);
    "etc/openbao-agent/templates/router-key.ctmpl" =
      builtins.readFile ../templates/bao-agent/router-key.ctmpl;
    "etc/openbao-agent/templates/vikunja-token.ctmpl" =
      builtins.readFile ../templates/bao-agent/vikunja-token.ctmpl;
    "etc/openbao-agent/templates/zammad-token.ctmpl" =
      builtins.readFile ../templates/bao-agent/zammad-token.ctmpl;
    "etc/openbao-agent/templates/opencode-config.ctmpl" =
      builtins.readFile ../templates/bao-agent/opencode-config.ctmpl;
    "etc/openbao-agent/templates/zcode-mcp.ctmpl" =
      builtins.readFile ../templates/bao-agent/zcode-mcp.ctmpl;
    "etc/openbao-agent/templates/zcode-mcp-public.ctmpl" =
      builtins.readFile ../templates/bao-agent/zcode-mcp-public.ctmpl;
    "etc/openbao-agent/templates/qwen-mcp.ctmpl" =
      builtins.readFile ../templates/bao-agent/qwen-mcp.ctmpl;
  };

  zcodeInstructions = writeTextDir "${lib.removePrefix "/" homeDir}/.zcode/AGENTS.md" (
    builtins.readFile ../templates/zcode/AGENTS.md
  );

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

  contents =
    toolPackages
    ++ basePackages
    ++ configFiles
    ++ baoAgentFiles
    ++ [
      profilesFile
      zcodeInstructions
      etcFiles
    ];

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
      # This is the bundled provider catalog consumed alongside ZCode's
      # personal provider config (see nix-ai modules/zcode/web.nix).
      "ZCODE_BUILTIN_PROVIDER_CONFIG_FILE=${zcodeWeb}/lib/zcode/apps/zcode-cli/packages/cli/dist/provider/zcode-builtin.json"
      "AGENT_MCP_VIKUNJA_COMMAND=${vikunjaMcp}/bin/vikunja-mcp"
      "AGENT_MCP_ZAMMAD_COMMAND=${zammadMcp}/bin/sandbox-zammad-mcp"
      "AGENT_MCP_ZAMMAD_ARGS=[]"
      "PATH=/bin:/usr/bin"
    ];
  };
}
