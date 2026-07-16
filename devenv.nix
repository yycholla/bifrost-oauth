{ pkgs, inputs, ... }:

let
  artifacts = pkgs.callPackage ./package.nix {
    bifrostPackages = inputs.bifrost.packages.${pkgs.stdenv.hostPlatform.system};
    bifrostSource = inputs.bifrost;
  };
  inherit (artifacts) bifrostHttp package;
in
{
  languages.go = {
    enable = true;
    package = bifrostHttp.go;
  };

  packages = [
    pkgs.gcc
    bifrostHttp
  ];
  env.CGO_ENABLED = "1";

  outputs.default = package;

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

  processes.bifrost.exec = ''
    build-plugin
    mkdir -p "$DEVENV_STATE/bifrost"
    if [[ ! -e "$DEVENV_STATE/bifrost/config.json" ]]; then
      cp config.json "$DEVENV_STATE/bifrost/config.json"
    fi
    exec bifrost-http -app-dir "$DEVENV_STATE/bifrost" -host 127.0.0.1
  '';

  enterTest = ''
    go test ./...
  '';
}
