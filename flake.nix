{
  description = "Nix-built OCI runtime for fully autonomous AI coding agents — the container is the permission boundary";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # TODO(repin): point at github:dryvist/nix-ai once dryvist/nix-ai#939
    # (lib.renderAutonomous) merges to main.
    nix-ai.url = "github:dryvist/nix-ai/feat/autonomy-profiles";
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
        # Egress allowlist consumed by the (phase 2) proxy package, the
        # docker-host nftables rules, and the architecture docs.
        egressDomains = import ./nix/egress-domains.nix;
      };

      packages = forSystems allSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          agent-cli = pkgs.callPackage ./nix/agent-cli.nix { };
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
              nixfmt-rfc-style
              shellcheck
            ];
          };
        }
      );

      formatter = forSystems allSystems (system: (pkgsFor system).nixfmt-rfc-style);

      checks = forSystems allSystems (
        system:
        {
          agent-cli = self.packages.${system}.agent-cli;
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
