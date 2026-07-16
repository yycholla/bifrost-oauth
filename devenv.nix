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

  scripts.claude-bifrost.exec = ''
    export ANTHROPIC_BASE_URL=http://127.0.0.1:18080/anthropic
    export ANTHROPIC_AUTH_TOKEN=local-only
    export ANTHROPIC_DEFAULT_HAIKU_MODEL=codex-subscription/gpt-5.6-luna
    export ANTHROPIC_DEFAULT_SONNET_MODEL=codex-subscription/gpt-5.6-terra
    export ANTHROPIC_DEFAULT_OPUS_MODEL=codex-subscription/gpt-5.6-sol
    exec claude "$@"
  '';

  scripts.check-claude-bifrost.exec = ''
    response="$(claude-bifrost --model opus -p 'Reply exactly CLAUDE_BIFROST_OK')"
    if [[ "$response" != *CLAUDE_BIFROST_OK* ]]; then
      printf 'unexpected Claude response:\n%s\n' "$response" >&2
      exit 1
    fi
    printf '%s\n' "$response"
  '';

  processes.bifrost.exec = ''
    build-plugin
    mkdir -p "$DEVENV_STATE/bifrost"
    if [[ ! -e "$DEVENV_STATE/bifrost/config.json" ]]; then
      cp config.json "$DEVENV_STATE/bifrost/config.json"
    fi
    exec bifrost-http -app-dir "$DEVENV_STATE/bifrost" -host 127.0.0.1 -port 18080
  '';

  enterTest = ''
    go test ./...
  '';
}
