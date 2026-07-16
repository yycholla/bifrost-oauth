{
  pkgs,
  bifrostPackages,
}:

let
  inherit (pkgs) lib;

  bifrostUi = bifrostPackages.bifrost-ui.overrideAttrs (old: {
    # Upstream's Nix hash lags this pinned source commit.
    npmDeps = old.npmDeps.overrideAttrs {
      outputHash = "sha256-AM6Gbdj9mRjeI7mgc+WWiscEA81WRupbhzeAC6JO32c=";
    };
  });

  bifrostBase = bifrostPackages.bifrost-http.override {
    bifrost-ui = bifrostUi;
  };

  bifrostHttp = bifrostBase.overrideAttrs {
    # Upstream's Nix hash lags this pinned source commit.
    vendorHash = "sha256-IpSKJZ58R7/Ziz/KV9WqV09PoWr9FG1Pzup6UrqmilU=";
  };

  pluginSource = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./go.mod
      ./go.sum
      ./plugin.go
      ./plugin_test.go
    ];
  };

  buildGoModule = pkgs.buildGoModule.override { go = bifrostBase.go; };

  plugin = buildGoModule {
    pname = "bifrost-codex-oauth-plugin";
    version = "0.1.0";
    src = pluginSource;

    vendorHash = "sha256-Q7or1Ur0PDrDrXI8Ngaz0uUp8aQKsq5KQL9lSiSZxqk=";

    env.CGO_ENABLED = "1";
    nativeBuildInputs = [ pkgs.gcc ];

    buildPhase = ''
      runHook preBuild
      go build -trimpath -buildmode=plugin -o codex-oauth.so .
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm755 codex-oauth.so $out/lib/bifrost/plugins/codex-oauth.so
      runHook postInstall
    '';

    meta = {
      description = "Codex subscription OAuth plugin for Bifrost";
      license = lib.licenses.asl20;
      platforms = lib.platforms.linux;
    };
  };

  settings = {
    "$schema" = "https://www.getbifrost.ai/schema";
    providers.codex-subscription = {
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
        path = "./plugins/codex-oauth.so";
        config = { };
      }
    ];
  };

  configTemplate = (pkgs.formats.json { }).generate "bifrost-oauth.json" settings;

  launcher = pkgs.writeShellApplication {
    name = "bifrost-oauth";
    text = ''
      app_dir="''${BIFROST_APP_DIR:-''${XDG_STATE_HOME:-$HOME/.local/state}/bifrost-oauth}"
      ${pkgs.coreutils}/bin/mkdir -p "$app_dir/plugins"
      ${pkgs.coreutils}/bin/ln -sfn \
        ${plugin}/lib/bifrost/plugins/codex-oauth.so \
        "$app_dir/plugins/codex-oauth.so"
      if [[ ! -e "$app_dir/config.json" ]]; then
        ${pkgs.coreutils}/bin/install -m 600 ${configTemplate} "$app_dir/config.json"
      fi
      cd "$app_dir"
      exec ${bifrostHttp}/bin/bifrost-http \
        -app-dir "$app_dir" \
        -host 127.0.0.1 \
        "$@"
    '';
  };
  package = pkgs.symlinkJoin {
    name = "bifrost-oauth";
    paths = [
      bifrostHttp
      plugin
      launcher
    ];
    passthru = {
      inherit
        bifrostHttp
        configTemplate
        plugin
        settings
        ;
    };
    meta = bifrostHttp.meta // {
      description = "Full Bifrost gateway with subscription OAuth plugins";
      mainProgram = "bifrost-oauth";
      platforms = lib.platforms.linux;
    };
  };
in
{
  inherit
    bifrostHttp
    configTemplate
    package
    plugin
    settings
    ;
  default = package;
}
