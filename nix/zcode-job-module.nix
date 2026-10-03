{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.zcode-job;
  repoPattern = "[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}";
in
{
  options.programs.zcode-job = {
    disabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Disable the ZCode dispatcher client.";
    };
    sshHost = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]*");
      default = null;
      description = "SSH config alias for the restricted dispatcher account.";
    };
    allowedRepos = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching repoPattern);
      default = [ ];
      description = "Approved non-sensitive subset of the dispatcher installation's repositories.";
    };
    liveUrl = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "https://[^[:space:]]+");
      default = null;
      description = "SSO URL of the always-on upstream ZCode Web/Server session.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./zcode-job.nix { };
      description = "The ZCode job client package.";
    };
  };
  config = lib.mkIf (!cfg.disabled) {
    assertions = [
      {
        assertion = cfg.allowedRepos != [ ] && cfg.sshHost != null && cfg.liveUrl != null;
        message = "zcode-job requires an approved repository list, SSH alias and HTTPS session URL.";
      }
    ];
    home.packages = [ cfg.package ];
    xdg.configFile."zcode-job/config.json".text = builtins.toJSON {
      inherit (cfg) sshHost allowedRepos liveUrl;
    };
  };
}
