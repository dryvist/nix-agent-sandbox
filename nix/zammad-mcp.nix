{
  callPackage,
  lib,
  pyproject-build-systems,
  pyproject-nix,
  python312,
  src,
  uv2nix,
}:

let
  workspace = uv2nix.lib.workspace.loadWorkspace {
    workspaceRoot = src;
  };
  pythonSet = (callPackage pyproject-nix.build.packages { python = python312; }).overrideScope (
    lib.composeManyExtensions [
      pyproject-build-systems.overlays.default
      (workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      })
    ]
  );
  mkApplication = (callPackage pyproject-nix.build.util { }).mkApplication;
in
mkApplication {
  venv = pythonSet.mkVirtualEnv "mcp-zammad-env" workspace.deps.default;
  package = pythonSet.mcp-zammad;
}
