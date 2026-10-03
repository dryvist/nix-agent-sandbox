{
  description = "Nix-built OCI runtime for fully autonomous AI coding agents — the container is the permission boundary";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-ai.url = "github:dryvist/nix-ai/main";
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
          agent-cli = pkgs.callPackage ./nix/agent-cli.nix { };
          agent-dispatch = pkgs.callPackage ./nix/agent-dispatch.nix { };
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
        in
        {
          agent-cli = self.packages.${system}.agent-cli;
          # Builds (shellchecks) the dispatcher and runs its bats suite
          # against the built binaries, with docker/curl/setsid stubbed.
          agent-dispatch =
            pkgs.runCommand "agent-dispatch-tests"
              {
                nativeBuildInputs = with pkgs; [
                  bats
                  coreutils
                  gnutar
                  jq
                  (python3.withPackages (ps: [ ps.opentelemetry-proto ]))
                ];
              }
              ''
                cp -r ${./tests} tests
                chmod -R u+w tests
                patchShebangs tests
                AGENT_DISPATCH_BIN=${self.packages.${system}.agent-dispatch}/bin \
                  ENTRYPOINT=${./scripts/entrypoint.sh} \
                  bats tests
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
