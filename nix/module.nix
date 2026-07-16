{ self, bifrost }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.bifrost.oauth;
  system = pkgs.stdenv.hostPlatform.system;
  plugin = self.packages.${system}.codex-oauth-plugin;
  pluginPath = "/var/lib/bifrost/plugins/codex-oauth.so";
  reconciler = self.packages.${system}.bifrost-oauth-reconciler;
in
{
  imports = [ bifrost.nixosModules.bifrost ];

  options.services.bifrost.oauth = {
    enable = lib.mkEnableOption "subscription OAuth plugins";

    user = lib.mkOption {
      type = lib.types.str;
      description = "User whose Codex OAuth credentials Bifrost uses.";
      example = "alice";
    };

    codexHome = lib.mkOption {
      type = lib.types.str;
      default = "/home/${cfg.user}/.codex";
      defaultText = lib.literalExpression ''"/home/''${config.services.bifrost.oauth.user}/.codex"'';
      description = "Directory containing the Codex auth.json file.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          config.services.bifrost.package ? bifrostOAuthAbi
          &&
            config.services.bifrost.package.bifrostOAuthAbi
            == self.packages.${system}.codex-oauth-plugin.bifrostOAuthAbi;
        message = ''
          services.bifrost.package must preserve the bifrostOAuthAbi marker from
          this flake's bifrost-http output so the Go plugin ABI is guaranteed to match.
        '';
      }
    ];

    services.bifrost = {
      enable = true;
      package = lib.mkDefault self.packages.${system}.bifrost-http;
      environment.CODEX_HOME = cfg.codexHome;
      settings = import ./settings.nix { inherit pluginPath; };
    };

    systemd.services.bifrost = {
      # Bifrost persists plugin paths in config.db. Keep that path stable across
      # Nix store changes and migrate installations created before v0.1.3.
      preStart = lib.mkAfter ''
        ${reconciler}/bin/bifrost-oauth-reconcile-plugin \
          /var/lib/bifrost \
          ${plugin}/lib/bifrost/plugins/codex-oauth.so
      '';
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = cfg.user;
        PrivateUsers = lib.mkForce false;
        ProtectHome = lib.mkForce true;
        BindPaths = [ cfg.codexHome ];
      };
    };
  };
}
