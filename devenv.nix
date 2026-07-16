{ pkgs, inputs, ... }:

let
  # ponytail: no dashboard; restore Bifrost's UI package if local admin UI is needed.
  emptyUi = pkgs.runCommand "bifrost-empty-ui" { } ''
    mkdir -p $out/ui
    echo '<!doctype html><title>Bifrost</title>' > $out/ui/index.html
  '';
  bifrostBase = inputs.bifrost.packages.${pkgs.system}.bifrost-http.override {
    bifrost-ui = emptyUi;
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

  enterTest = ''
    go test ./...
  '';
}
