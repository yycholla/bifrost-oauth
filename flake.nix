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
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${(artifactsFor system).package}/bin/bifrost-oauth";
        };
      });

      checks = forAllSystems (system: {
        package = (artifactsFor system).package;
      });

      nixosModules.default = import ./nix/module.nix { inherit self bifrost; };
    };
}
