# The common repo-check toolchain baked into the agent image.
#
# Coding jobs cannot install check tools at job time: the egress proxy
# denies PyPI and general package hosts, and `nix develop` only helps
# repos whose own flake declares the tools in a devShell. Everything in
# checkToolchain comes from the pinned nixpkgs input and runs without
# network. jq is already a base image package (agent-image.nix); it is
# named in requiredBinaries so every consumer asserts one list.
#
# requiredBinaries is the enforced contract:
#   .#checks.<system>.agent-image-toolchain — merges checkToolchain and
#     fails the build if any binary is absent;
#   tests/agent-image-smoke.bats — runs the same list inside the built
#     image with networking disabled.
{
  jq,
  python3,
  python3Packages,
  pre-commit,
  yq-go,
  yamllint,
  ruff,
  shellcheck,
  actionlint,
  nixfmt,
  ansible-lint,
}:
let
  pythonEnv = python3.withPackages (
    ps: with ps; [
      pytest
      pyyaml
      jinja2
    ]
  );
in
{
  inherit pythonEnv;

  checkToolchain = [
    pythonEnv
    pre-commit
    yq-go # mikefarah Go yq v4; nixpkgs' plain `yq` is the Python port
    yamllint
    ruff
    shellcheck
    actionlint
    nixfmt
    python3Packages.ansible-core
    ansible-lint
  ];

  requiredBinaries = [
    "actionlint"
    "ansible-lint"
    "ansible-playbook"
    "jq"
    "nixfmt"
    "pre-commit"
    "pytest"
    "python3"
    "ruff"
    "shellcheck"
    "yamllint"
    "yq"
  ];
}
