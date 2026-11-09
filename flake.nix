{
  description = "Nix-built OCI runtime for fully autonomous AI coding agents — the container is the permission boundary";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-ai = {
      url = "github:dryvist/nix-ai?ref=v8";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixpkgs-unstable.follows = "nixpkgs";
    };
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zammadMcpSrc = {
      url = "github:basher83/Zammad-MCP/v1.2.0";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nix-ai,
      llm-agents,
      pyproject-nix,
      pyproject-build-systems,
      uv2nix,
      zammadMcpSrc,
    }:
    let
      inherit (nixpkgs) lib;

      # The image is Linux-only (OCI); the CLI runs anywhere the runtimes do.
      linuxSystems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      allSystems = linuxSystems ++ [ "aarch64-darwin" ];
      forSystems = systems: f: lib.genAttrs systems f;

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          # claude-code is unfree.
          config.allowUnfreePredicate =
            pkg:
            lib.elem (lib.getName pkg) [
              "claude-code"
            ];
        };
    in
    {
      lib = {
        # Egress allowlist consumed by the Docker host's egress proxy and the
        # architecture docs.
        egressDomains = import ./nix/egress-domains.nix;
        # Task profiles (required environment variables per profile); baked
        # into the image and the CLI, exported for docs and consumers.
        taskProfiles = import ./nix/task-profiles.nix;
        # Repo groups: named sets of repos, exported for docs and consumers.
        repoGroups = import ./nix/repo-groups.nix;
      };

      homeManagerModules.zcode-job = import ./nix/zcode-job-module.nix;

      packages = forSystems allSystems (
        system:
        let
          pkgs = pkgsFor system;
          zammadMcpPackage = pkgs.callPackage ./nix/zammad-mcp.nix {
            inherit pyproject-nix pyproject-build-systems uv2nix;
            src = zammadMcpSrc;
          };
          repoCheckToolchain = pkgs.callPackage ./nix/agent-image-toolchain.nix { };
        in
        {
          agent-cli = pkgs.callPackage ./nix/agent-cli.nix { };
          agent-dispatch = pkgs.callPackage ./nix/agent-dispatch.nix { };
          ci-resolver = pkgs.writeShellApplication {
            name = "ci-resolver";
            runtimeInputs = [
              pkgs.git
              pkgs.python3
            ];
            text = ''
              exec python3 ${./scripts/ci-resolver.py} "$@"
            '';
          };
          zammad-mcp = zammadMcpPackage;
          zcode-job = pkgs.callPackage ./nix/zcode-job.nix { };
          default = self.packages.${system}.agent-cli;
        }
        // lib.optionalAttrs (lib.elem system linuxSystems) {
          agent-image =
            let
              npmMcpPackages = import "${nix-ai.outPath}/modules/mcp/packages-npm.nix" { inherit pkgs; };
            in
            pkgs.callPackage ./nix/agent-image.nix {
              renderAutonomous = nix-ai.lib.renderAutonomous;
              inherit repoCheckToolchain;
              zcodeWeb = nix-ai.packages.${system}.zcode-web;
              vikunjaMcp = npmMcpPackages.vikunja-mcp;
              zammadMcp = zammadMcpPackage;
              inherit (pkgs) opencode;
              cursorAgent = llm-agents.packages.${system}.cursor-agent;
              qwenCode = llm-agents.packages.${system}.qwen-code;
            };
        }
      );

      devShells = forSystems allSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              bats
              nixfmt
              shellcheck
            ];
          };
        }
      );

      formatter = forSystems allSystems (system: (pkgsFor system).nixfmt);

      checks = forSystems allSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          agent-cli = self.packages.${system}.agent-cli;
          ci-resolver =
            pkgs.runCommand "ci-resolver-tests"
              {
                nativeBuildInputs = [
                  pkgs.git
                  pkgs.python3
                ];
              }
              ''
                cp -r ${./scripts} scripts
                cp -r ${./tests} tests
                chmod -R u+w scripts tests
                PYTHONPATH="$PWD/scripts" python3 -m unittest discover -s tests -p 'test_ci_resolver.py'
                touch $out
              '';
          # Builds (shellchecks) the dispatcher and runs its bats suite
          # against the built binaries, with docker/curl/setsid stubbed.
          agent-dispatch =
            pkgs.runCommand "agent-dispatch-tests"
              {
                nativeBuildInputs = with pkgs; [
                  bats
                  coreutils
                  git
                  gnutar
                  jq
                  openbao
                  python3
                ];
                # The OpenBao Agent test runs a loopback dev server.
                __darwinAllowLocalNetworking = true;
              }
              ''
                cp -r ${./tests} tests
                cp -r ${./templates} templates
                chmod -R u+w tests templates
                patchShebangs tests
                AGENT_DISPATCH_BIN=${self.packages.${system}.agent-dispatch}/bin \
                  ENTRYPOINT=${./scripts/entrypoint.sh} \
                  BAO_BIN=${pkgs.openbao}/bin/bao \
                  ZAMMAD_MCP_WRAPPER_SOURCE=${./scripts/zammad-mcp.sh} \
                  bats tests/agent-dispatch.bats tests/agent-bao-agent.bats
                touch $out
              '';
          agent-cli-spool =
            pkgs.runCommand "agent-cli-spool-tests"
              {
                nativeBuildInputs = with pkgs; [
                  bats
                  coreutils
                  gnused
                ];
              }
              ''
                AGENT_CLI_SOURCE=${./scripts/agent-cli.sh} \
                  bats ${./tests/agent-cli-spool.bats}
                touch $out
              '';
          zcode-job =
            let
              sshStub = pkgs.writeShellApplication {
                name = "ssh";
                runtimeInputs = [ pkgs.jq ];
                text = builtins.readFile ./tests/ssh-stub.sh;
              };
              client = self.packages.${system}.zcode-job.override { openssh = sshStub; };
            in
            pkgs.runCommand "zcode-job-tests"
              {
                nativeBuildInputs = with pkgs; [
                  bats
                  coreutils
                  jq
                ];
              }
              ''
                ZCODE_JOB_BIN=${client}/bin ZCODE_JOB_SCRIPTS=${./scripts} \
                  bats ${./tests/zcode-job.bats}
                touch $out
              '';
          zcode-job-module =
            let
              allowedRepos =
                (pkgs.lib.evalModules {
                  modules = [
                    self.homeManagerModules.zcode-job
                    {
                      _module.args.pkgs = pkgs;
                      _module.check = false;
                    }
                  ];
                }).options.programs.zcode-job.allowedRepos.type.nestedTypes.elemType.check;
            in
            assert allowedRepos "owner/repo" && allowedRepos "Owner/*";
            assert !(allowedRepos "owner/*x");
            assert !(allowedRepos "*/repo");
            pkgs.runCommand "zcode-job-module-tests" { } "touch $out";
          # Fails unless every repo-check binary the image bakes onto PATH
          # is present in a /bin merged from the same package list.
          agent-image-toolchain =
            let
              toolchain = pkgs.callPackage ./nix/agent-image-toolchain.nix { };
              binTree = pkgs.symlinkJoin {
                name = "agent-image-toolchain-bin";
                paths = toolchain.checkToolchain ++ [ pkgs.jq ];
                pathsToLink = [ "/bin" ];
              };
            in
            pkgs.runCommand "agent-image-toolchain-tests"
              {
                nativeBuildInputs = [ pkgs.coreutils ];
              }
              ''
                for binary in ${lib.escapeShellArgs toolchain.requiredBinaries}; do
                  test -x "${binTree}/bin/$binary" || {
                    printf 'missing from the image PATH: %s\n' "$binary" >&2
                    exit 1
                  }
                done
                ${toolchain.pythonEnv}/bin/python3 -c 'import pytest, yaml, jinja2'
                touch $out
              '';
          sandbox-contract =
            pkgs.runCommand "sandbox-contract-tests"
              {
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                cat > profiles.json <<'EOF'
                ${builtins.toJSON (import ./nix/task-profiles.nix)}
                EOF
                cat > egress.json <<'EOF'
                ${builtins.toJSON (import ./nix/egress-domains.nix)}
                EOF
                jq -e '
                  .zai.env == ["ZAI_SUBSCRIPTION_KEY"] and
                  ([to_entries[] | select(.value.batchCapable == true) | .key] | sort) == ["dev", "opencode", "opencode-local", "opencode-zai", "qwen", "qwen-code", "zai", "zcode", "zcode-web"] and
                  .zcode.env == [] and .zcode.trackerAccess == false and
                  (.zcode | has("routerKeyField") or has("sandboxRouterKeyField") | not) and
                  ([to_entries[] | select((.key == "zcode" or .key == "opencode" or .key == "opencode-local") | not) | .value] | all(has("trackerAccess") | not)) and
                  .opencode.trackerAccess == false and .["opencode-local"].trackerAccess == false and
                  .opencode.env == [] and .opencode.routerKeyField == "OPENCODE_ROUTER_KEY" and
                  .opencode.sandboxRouterKeyField == "sandbox_agent_router_llm_router_key" and
                  .["opencode-local"].env == [] and .["opencode-local"].routerKeyField == "OPENCODE_LOCAL_ROUTER_KEY" and
                  .["opencode-local"].sandboxRouterKeyField == "sandbox_agent_local_router_llm_router_key" and
                  .["opencode-zai"].env == ["ZAI_SUBSCRIPTION_KEY", "ZAI_MODEL"] and
                  .shell.env == [] and (.shell | has("routerKeyField") or has("ttyLogin") | not) and
                  .["cursor-agent"].env == [] and .["cursor-agent"].ttyLogin == true and
                  .["qwen-code"].env == [] and .["qwen-code"].routerKeyField == "QWEN_CODE_ROUTER_KEY" and
                  .["qwen-code"].sandboxRouterKeyField == "sandbox_agent_router_llm_router_key" and
                  (.["qwen-code"] | has("ttyLogin") | not) and
                  (.["cursor-agent"] | has("routerKeyField") | not) and
                  ([.zcode, .opencode, .["cursor-agent"]] | all(.ttyLogin == true)) and
                  ([.["opencode-local"], .["opencode-zai"]] | all(has("ttyLogin") | not)) and
                  .["zcode-web"].env == ["ZAI_SUBSCRIPTION_KEY", "AGENT_WEB_TOKEN"]
                ' profiles.json >/dev/null
                jq -e '
                  .zai == ["api.z.ai", "cdn-zcode.z.ai", "chat.z.ai", "zcode.z.ai"] and
                  .cursorAgent == [".cursor.sh", ".cursorapi.com"] and
                  .opencode == ["opencode.ai"] and
                  ([.modelApis[] | select(test("gemini|google"; "i"))] | length) == 0
                ' egress.json >/dev/null
                touch $out
              '';
        }
        // lib.optionalAttrs (lib.elem system linuxSystems) {
          # Building the image derivation also validates the rendered
          # autonomous configs baked into it (nix-ai's own checks assert
          # their content).
          agent-image = self.packages.${system}.agent-image;
        }
      );
    };
}
