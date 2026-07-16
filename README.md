# Bifrost Codex subscription OAuth

Native Bifrost plugin that reuses an existing `codex login` to send Responses requests through the ChatGPT Codex subscription backend.

This uses the private `chatgpt.com/backend-api/codex` endpoint. It is not an officially supported general OpenAI API integration and may break when that backend changes.

## Build

```bash
devenv shell
build-plugin
devenv build outputs.default
```

The plugin and Bifrost must use the same Go version, Bifrost core revision and module identity, build flags, architecture, and libc. The devenv pins both to Bifrost commit `c0909f9`, builds the plugin against that input's local core source, and includes the dynamically linked `bifrost-http` binary.

The full Bifrost dashboard and backend are included. Build the plugin and start
the loopback-only instance with:

```bash
devenv up
```

Run it as your user so the plugin can read `~/.codex/auth.json`. `CODEX_HOME`
is honored when set.

The same package is exposed as a standard flake output:

```bash
nix build path:.
nix run path:.
```

`bifrost-oauth` stores mutable state under `$XDG_STATE_HOME/bifrost-oauth` (or
`~/.local/state/bifrost-oauth`).
Override that location with `BIFROST_APP_DIR`. The default listener remains
`127.0.0.1:8080`.

For NixOS, import `nixosModules.default` and enable the plugin on top of
Bifrost's existing module:

```nix
{
  imports = [ inputs.bifrost-oauth.nixosModules.default ];
  services.bifrost.oauth = {
    enable = true;
    user = "alice";
  };
}
```

The module selects this flake's `bifrost-http` output so the Go plugin ABI
matches. A wrapper around that exact binary must preserve its
`bifrostOAuthAbi` passthru marker. Overriding `services.bifrost.package` with a
separately rebuilt Bifrost fails NixOS evaluation instead of leaving a plugin
that Bifrost will reject at runtime.

The ChatGPT Codex backend requires streaming Responses requests. Claude Code uses the streaming path; direct clients must set `stream: true`.

Point Claude Code at the Anthropic integration:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8080/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "local-only",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "codex-subscription/gpt-5.4-mini",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "codex-subscription/gpt-5.4"
  }
}
```

The plugin refreshes rotating OAuth credentials and atomically replaces the Codex auth file with mode `0600`. If Codex rotates the token concurrently, the plugin rereads and uses Codex's newly persisted credentials.

## Check

```bash
devenv test
```
