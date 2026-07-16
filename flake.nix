{
  description = "Full Bifrost gateway with subscription OAuth plugins";

  inputs = {
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    bifrost.url = "github:maximhq/bifrost/c0909f9752156121c6c775694df6e656a6ad3860";
  };

  outputs =
    {
      self,
      nixpkgs,
      bifrost,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      artifactsFor =
        system:
        nixpkgs.legacyPackages.${system}.callPackage ./package.nix {
          bifrostPackages = bifrost.packages.${system};
          bifrostSource = bifrost;
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          artifacts = artifactsFor system;
        in
        {
          default = artifacts.package;
          bifrost-oauth = artifacts.package;
          bifrost-http = artifacts.bifrostHttp;
          codex-oauth-plugin = artifacts.plugin;
          bifrost-oauth-reconciler = artifacts.reconciler;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${(artifactsFor system).package}/bin/bifrost-oauth";
        };
      });

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          artifacts = artifactsFor system;
        in
        {
          package = artifacts.package;
          plugin-upgrade =
            pkgs.runCommand "bifrost-oauth-plugin-upgrade-check"
              {
                nativeBuildInputs = [
                  artifacts.reconciler
                  pkgs.sqlite
                ];
              }
              ''
                state="$TMPDIR/bifrost"
                mkdir -p "$state"
                sqlite3 "$state/config.db" \
                  "CREATE TABLE config_plugins (name TEXT, path TEXT); INSERT INTO config_plugins VALUES ('codex-subscription-oauth', '/nix/store/old/plugin.so'), ('other-plugin', '/keep/me.so');"

                bifrost-oauth-reconcile-plugin \
                  "$state" \
                  ${artifacts.plugin}/lib/bifrost/plugins/codex-oauth.so

                test "$(readlink "$state/plugins/codex-oauth.so")" = \
                  "${artifacts.plugin}/lib/bifrost/plugins/codex-oauth.so"
                test "$(sqlite3 "$state/config.db" "SELECT path FROM config_plugins WHERE name = 'codex-subscription-oauth';")" = \
                  "$state/plugins/codex-oauth.so"
                test "$(sqlite3 "$state/config.db" "SELECT path FROM config_plugins WHERE name = 'other-plugin';")" = \
                  "/keep/me.so"
                touch "$out"
              '';
        }
      );

      nixosModules.default = import ./nix/module.nix { inherit self bifrost; };
    };
}
