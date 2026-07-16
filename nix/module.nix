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
    services.bifrost = {
      enable = true;
      package = self.packages.${system}.bifrost-http;
      environment.CODEX_HOME = cfg.codexHome;
      settings = {
        providers."codex-subscription" = {
          network_config.base_url = "https://chatgpt.com/backend-api/codex";
          openai_config.disable_store = true;
          custom_provider_config = {
            base_provider_type = "openai";
            is_key_less = true;
            allowed_requests.responses_stream = true;
            request_path_overrides.responses_stream = "/responses";
          };
        };
        plugins = [
          {
            name = "codex-subscription-oauth";
            enabled = true;
            path = "${self.packages.${system}.codex-oauth-plugin}/lib/bifrost/plugins/codex-oauth.so";
            config = { };
          }
        ];
      };
    };

    systemd.services.bifrost.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = cfg.user;
      PrivateUsers = lib.mkForce false;
      ProtectHome = lib.mkForce "read-only";
      ReadWritePaths = [ cfg.codexHome ];
    };
  };
}
