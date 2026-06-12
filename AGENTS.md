# nix-agent-sandbox conventions

Read [README.md](README.md) first for what this repo is.

## Invariants

- The autonomous tool configs come ONLY from `dryvist/nix-ai`
  `lib.renderAutonomous.files`. Never hand-write a Claude/Codex/Gemini
  config in this repo; change the source list in nix-ai instead so all
  three tools stay in lockstep.
- The image runs as `agent` (uid 1000). Never add sudo, never run the
  entrypoint as root, never remove the `AGENT_SANDBOX`/non-root guards.
- Shell scripts live in `scripts/` and are referenced from Nix via
  `builtins.readFile` + `writeShellApplication` — never inline in `.nix`.
- Egress domains (`nix/egress-domains.nix`) are a reviewed allowlist;
  additions are deliberate, one-domain-at-a-time changes.

## Build & verify

```sh
nix flake check -L          # all systems' checks for this host
nix build .#agent-image     # Linux only (CI builds both arches)
nix run .#agent-cli -- run --tool claude "hello"   # needs container/docker + image
```

The image build requires a Linux builder; on the Mac, rely on CI (GHCR
publish) and pull the published image for local smoke tests.

## Flake input pinning

`nix-ai` is pinned to the `feat/autonomy-profiles` branch until
dryvist/nix-ai#939 merges — repoint to the default branch afterwards
(tracked by the TODO(repin) comment in flake.nix).
