{
  description = "Nix-built OCI runtime for fully autonomous AI coding agents — the container is the permission boundary";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-ai.url = "github:dryvist/nix-ai/afbfa0a8c92f5d723d9264af8efb337e4b2186f4";
  };

  outputs =
    {
      self,
      nixpkgs,
      nix-ai,
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
          # claude-code is unfree; codex and gemini-cli are Apache-2.0.
          config.allowUnfreePredicate = pkg: lib.getName pkg == "claude-code";
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
        # Repo groups: named fan-out sets for `agent sweep`. Baked into the
        # CLI as JSON (agent-cli.nix), exported for docs and consumers.
        repoGroups = import ./nix/repo-groups.nix;
      };

      packages = forSystems allSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          agent-cli = pkgs.callPackage ./nix/agent-cli.nix {
            agentNofile = nix-ai.lib.agentNofile;
          };
          agent-dispatch = pkgs.callPackage ./nix/agent-dispatch.nix {
            agentNofile = nix-ai.lib.agentNofile;
          };
          default = self.packages.${system}.agent-cli;
        }
        // lib.optionalAttrs (lib.elem system linuxSystems) {
          agent-image = pkgs.callPackage ./nix/agent-image.nix {
            renderAutonomous = nix-ai.lib.renderAutonomous;
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
          dispatchCheck =
            agentNofile: filter:
            pkgs.runCommand "agent-dispatch-tests"
              {
                nativeBuildInputs = with pkgs; [
                  bats
                  coreutils
                  gnutar
                  jq
                ];
              }
              ''
                cp -r ${./tests} tests
                chmod -R u+w tests
                patchShebangs tests
                mkdir -p $out
                export NOFILE_EVIDENCE_DIR=$out
                export EXPECTED_NOFILE=${toString agentNofile}
                export AGENT_CLI_BIN=${self.packages.${system}.agent-cli.override { inherit agentNofile; }}/bin
                export AGENT_DISPATCH_BIN=${
                  self.packages.${system}.agent-dispatch.override { inherit agentNofile; }
                }/bin
                export ENTRYPOINT=${./scripts/entrypoint.sh}
                set -o pipefail
                bats ${filter} tests | tee $out/tests.tap
              '';
        in
        {
          agent-cli = self.packages.${system}.agent-cli;
          # Exercise built binaries against docker/curl/setsid stand-ins.
          agent-dispatch = dispatchCheck nix-ai.lib.agentNofile "";
          agent-nofile-override = dispatchCheck (nix-ai.lib.agentNofile + 1) "--filter nofile";
          agent-nofile-no-literals = pkgs.runCommand "agent-nofile-no-literals" { } ''
            if grep -nE '(AGENT_NOFILE[[:space:]]*=|agentNofile[[:space:]]*[?=]|nofile=).*[0-9]' \
              ${./nix/agent-cli.nix} ${./nix/agent-dispatch.nix} \
              ${./scripts/agent-cli.sh} ${./scripts/agent-dispatch.sh} \
              <(sed '/^      checks =/,$d' ${./flake.nix}); then
              echo "consumer defines a numeric nofile policy" >&2
              exit 1
            fi
            echo "No numeric nofile policy in consumers" > $out
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
