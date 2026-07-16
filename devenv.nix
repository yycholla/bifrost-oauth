{ pkgs, inputs, ... }:

let
  bifrostUi =
    inputs.bifrost.packages.${pkgs.stdenv.hostPlatform.system}.bifrost-ui.overrideAttrs
      (old: {
        # Upstream's Nix hash lags this pinned source commit.
        npmDeps = old.npmDeps.overrideAttrs {
          outputHash = "sha256-AM6Gbdj9mRjeI7mgc+WWiscEA81WRupbhzeAC6JO32c=";
        };
      });
  bifrostBase = inputs.bifrost.packages.${pkgs.stdenv.hostPlatform.system}.bifrost-http.override {
    bifrost-ui = bifrostUi;
  };
  bifrost = bifrostBase.overrideAttrs {
    # Upstream's Nix hash lags this pinned source commit.
    vendorHash = "sha256-IpSKJZ58R7/Ziz/KV9WqV09PoWr9FG1Pzup6UrqmilU=";
  };
in
{
  languages.go = {
    enable = true;
    package = bifrostBase.go;
  };

  packages = [
    pkgs.gcc
    bifrost
  ];
  env.CGO_ENABLED = "1";

  scripts.build-plugin.exec = ''
    mkdir -p build
    cp go.mod build/plugin.mod
    cp go.sum build/plugin.sum
    go mod edit -modfile=build/plugin.mod \
      -require=github.com/maximhq/bifrost/core@v1.7.1 \
      -replace=github.com/maximhq/bifrost/core=${inputs.bifrost}/core
    go build -trimpath -buildmode=plugin -modfile=build/plugin.mod \
      -o build/codex-oauth.so .
  '';

  processes.bifrost.exec = "build-plugin && exec bifrost-http -app-dir . -host 127.0.0.1";

  enterTest = ''
    go test ./...
  '';
}
