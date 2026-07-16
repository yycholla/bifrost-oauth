{
  pkgs,
  bifrostPackages,
  bifrostSource,
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

  bifrostOAuthAbi = builtins.hashString "sha256" "${bifrostSource}:${bifrostBase.go}";

  bifrostHttp = bifrostBase.overrideAttrs (previous: {
    # Upstream's Nix hash lags this pinned source commit.
    vendorHash = "sha256-IpSKJZ58R7/Ziz/KV9WqV09PoWr9FG1Pzup6UrqmilU=";
    passthru = (previous.passthru or { }) // {
      inherit bifrostOAuthAbi;
    };
  });

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

  usePinnedCore = ''
    cp -R ${bifrostSource}/core bifrost-core
    chmod -R u+w bifrost-core
    go mod edit \
      -require=github.com/maximhq/bifrost/core@v1.7.1 \
      -replace=github.com/maximhq/bifrost/core=./bifrost-core
  '';

  plugin = buildGoModule {
    pname = "bifrost-codex-oauth-plugin";
    version = "0.1.1";
    src = pluginSource;

    vendorHash = "sha256-dRvYRt6Dq0VNsZtzWITx9y2GAzfx8v3E8u5jeIN2oz8=";

    overrideModAttrs = final: previous: {
      postPatch = (previous.postPatch or "") + usePinnedCore;
    };
    postPatch = usePinnedCore;

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

    passthru = { inherit bifrostOAuthAbi; };

    meta = {
      description = "Codex subscription OAuth plugin for Bifrost";
      license = lib.licenses.asl20;
      platforms = lib.platforms.linux;
    };
  };

  settings = import ./nix/settings.nix {
    pluginPath = "./plugins/codex-oauth.so";
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
        bifrostOAuthAbi
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
    bifrostOAuthAbi
    configTemplate
    package
    plugin
    settings
    ;
  default = package;
}
