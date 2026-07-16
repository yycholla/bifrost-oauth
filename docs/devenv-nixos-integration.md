# Devenv → NixOS integration

Verified 2026-07-16 against the live Devenv documentation and this project's pinned Devenv revision, [`4ed83c0`](https://github.com/cachix/devenv/tree/4ed83c00354d5a6b4cece8aa8c55028b4e4421e4).

## Answer

Devenv **does support buildable package outputs**: `outputs.<name>` may be a Nix derivation, and `devenv build` builds it for installation or distribution. It is therefore reasonable to package this application in `devenv.nix`. [`outputs` docs](https://devenv.sh/outputs/) · [source](https://github.com/cachix/devenv/blob/4ed83c00354d5a6b4cece8aa8c55028b4e4421e4/docs/src/outputs.md#L7-L16)

That does **not** make the repository a standard Nix flake package or NixOS module automatically. Devenv's flake integration creates `devShells`; its official flake-parts example defines `packages.default` separately and then reuses that package in the shell. [`flakeModule` source](https://github.com/cachix/devenv/blob/4ed83c00354d5a6b4cece8aa8c55028b4e4421e4/flake-module.nix#L25-L47) · [official example](https://devenv.sh/guides/using-with-flake-parts/#the-flakenix-file)

So the precise answer for this repository is: **Devenv can produce the package, but the current checkout is not yet directly addable to a NixOS flake configuration.** It has no `outputs` entry or `flake.nix`, and its plugin is currently built imperatively into `build/codex-oauth.so` rather than into a Nix derivation ([`devenv.nix`](../devenv.nix)).

## What the similarly named features mean

- `packages = [ ... ]` adds tools and libraries to the activated development shell's `PATH`; it is not an exported package set. [Packages docs](https://devenv.sh/packages/) · [source](https://github.com/cachix/devenv/blob/4ed83c00354d5a6b4cece8aa8c55028b4e4421e4/docs/src/packages.md#L1-L35)
- `outputs.<name> = derivation` marks buildable Devenv outputs. `devenv build` builds all outputs, and `devenv build outputs.<name>` builds one. [Outputs docs](https://devenv.sh/outputs/#building-outputs) · [source](https://github.com/cachix/devenv/blob/4ed83c00354d5a6b4cece8aa8c55028b4e4421e4/docs/src/outputs.md#L40-L63)
- Another **Devenv** project can consume these through `inputs.<name>.devenv.config.outputs.<name>` in Devenv 2.0. This is Devenv's own input evaluation surface, not a standard `packages.<system>` flake output. [Polyrepo guide](https://devenv.sh/guides/polyrepo/#referencing-config-across-inputs) · [source](https://github.com/cachix/devenv/blob/4ed83c00354d5a6b4cece8aa8c55028b4e4421e4/docs/src/guides/polyrepo.md#L62-L90)
- `devenv.lib.mkShell` evaluates Devenv modules and returns the development shell plus attached `config` and `ci`; the official guide places it under `devShells.<system>.default`. [Flakes guide](https://devenv.sh/guides/using-with-flakes/#the-flakenix-file) · [implementation](https://github.com/cachix/devenv/blob/4ed83c00354d5a6b4cece8aa8c55028b4e4421e4/flake.nix#L187-L238)
- `inputs.devenv.flakeModule` is the flake-parts integration. It maps `devenv.shells.<name>` to `devShells.<name>`; it does not map Devenv `outputs` to standard flake `packages`. [Guide](https://devenv.sh/guides/using-with-flake-parts/) · [implementation](https://github.com/cachix/devenv/blob/4ed83c00354d5a6b4cece8aa8c55028b4e4421e4/flake-module.nix#L25-L47)
- `processes` remain development processes launched by `devenv up`. The flake integration's generated `devenv-up` package is explicitly deprecated, so it is not a NixOS/systemd service integration. [Processes docs](https://devenv.sh/processes/#basic-example) · [`flakeModule` source](https://github.com/cachix/devenv/blob/4ed83c00354d5a6b4cece8aa8c55028b4e4421e4/flake-module.nix#L49-L76)

## Minimal shape for this repository

Use one real package derivation and expose it through both interfaces:

```text
package.nix   complete Bifrost + dashboard + codex-oauth.so derivation
devenv.nix    outputs.default = callPackage ./package.nix { ... };
flake.nix     packages.<system>.default = callPackage ./package.nix { ... };
```

The package must build the plugin in the Nix store with the same pinned Bifrost source, Go toolchain, libc, and plugin build flags already enforced by the development script. Merely setting `outputs.default = bifrost` would omit `codex-oauth.so`.

The minimal `flake.nix` need not adopt flake-parts just to export one package:

```nix
{
  inputs = {
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    bifrost.url = "github:maximhq/bifrost/c0909f9752156121c6c775694df6e656a6ad3860";
  };

  outputs = inputs@{ nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages.${system}.default = pkgs.callPackage ./package.nix { inherit inputs; };
    };
}
```

Then a NixOS configuration can install it directly:

```nix
environment.systemPackages = [
  inputs.bifrost-codex-oauth.packages.${pkgs.stdenv.hostPlatform.system}.default
];
```

Keep `processes.bifrost` for `devenv up`. Add a small `nixosModules.default` only if the repository should also own daemon lifecycle; Devenv does not synthesize it. The official Devenv flake-parts template explicitly leaves normal flake attributes such as `nixosModule` for the project to define. [Official template source](https://github.com/cachix/devenv/blob/4ed83c00354d5a6b4cece8aa8c55028b4e4421e4/templates/flake-parts/flake.nix#L58-L63)

For this application that service should run as the logged-in Codex user (or receive an explicit user/home option), because the plugin reads and updates that user's `~/.codex/auth.json`. Installation alone does not require a NixOS module.
