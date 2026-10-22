# Nix / NixOS

The flake packages the official Linux release binaries (`x86_64-linux` and `aarch64-linux`) from [i2cjak/Backplane](https://github.com/i2cjak/Backplane). nixpkgs is pinned to `nixos-26.05`. `packages.default` is `backplane` (that tarball). `overlays.default` adds it, plus `backplane-src` and `bend` on `x86_64-linux`. `apps.default` runs the release binary. `nix fmt` is alejandra.

`backplane-src` compiles this checkout with `scripts/build.sh`: `backplane` (the launcher), `backplane-serve`, `web/`, and `kistack/` under `libexec/backplane`, and `backplane-kipc`. KiStack is the same `fetchFromGitHub` pin as the release package (`nix/sources.nix`, from `deploy/kistack.lock`). Bend is 2.0.36 on a baseline Bun, so the compiler runs on CPUs without AVX2. Google sign-in is not baked in. `backplane-browser` and `backplane-step2glb` are not built.

```sh
nix build .#backplane-src
```

```sh
nix run .          # the window binary; a hub starts with it
nix build
nix flake check
```

There is no `--version`. An unknown flag is ignored, and a hub would start on the default home. The version is the `backplane` field of `GET /hello`, which is CBOR, not a text banner. The flake's `version` check starts the packaged binary and reads that.

A NixOS configuration:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.backplane.url = "github:Riceman2000/Backplane";

  outputs = { nixpkgs, backplane, ... }: {
    nixosConfigurations.box = nixpkgs.lib.nixosSystem {
      modules = [
        backplane.nixosModules.default
        { nixpkgs.overlays = [ backplane.overlays.default ]; }
        ({ pkgs, ... }: {
          services.backplane = {
            enable = true;
            # "release" (default) is pkgs.backplane, the pinned tarball.
            # "source" is pkgs.backplane-src, this checkout (x86_64-linux).
            # Setting `package` directly overrides `variant`.
            variant = "release";
            # Loopback unless you mean to publish the hub.
            host = "127.0.0.1";
            port = 3787;
            openFirewall = false;
            tailscale.enable = true;
            extraPackages = [ pkgs.git pkgs.kicad pkgs.freecad ];
            # Strings, not path literals. A path would be copied into the
            # Nix store, and the module rejects store paths.
            environmentFile = "/run/secrets/backplane.env";
            credentials.CLAUDE_CODE_OAUTH_TOKEN = "/run/secrets/claude-token";
          };
        })
      ];
    };
  };
}
```

The service runs `backplane-serve` (it stays in the foreground; `backplane --headless` without `--foreground` detaches). State is `--home` (`/var/lib/backplane` by default), owned by the `backplane` user. `XDG_CACHE_HOME` is `/var/cache/backplane`. The package and the unit set `BACKPLANE_NO_UPDATE=1`. The account lingers so upstream can put each agent in a `systemd-run --user` scope; without a user manager those agents run unconfined.

`tailscale.enable` puts `tailscale` on `PATH` and orders the service after `tailscaled.service` and `tailscaled-autoconnect.service` with `Wants=`, so a machine without the autoconnect unit still boots. Upstream reads `tailscale ip -4` once at start.

KiStack is loaded from the directory of the running binary, `<exe dir>/kistack`. Since v0.12.0 the hub does not fetch KiStack and does not read `$HOME/.cache/backplane/kistack`. The classic release archives omit that directory, so the package fetches the commit in `deploy/kistack.lock` (`github.com/American-Embedded/KiStack`; the lock names no subpath) and installs the tree `scripts/build-kistack.sh` writes: `skills/`, `LICENSE`, `.claude-plugin/plugin.json`, and `REVISION`, at `libexec/backplane/kistack`, beside `backplane` and `backplane-serve`. A `kistack/` directory already in a release archive is copied instead. The module does not seed a cache.

The pairing token is 128 hex characters in `<home>/token` (mode 0600). Upstream prints it on stdout only when the tailnet listener binds (`pairing token <hex>`, and `#token=<hex>` with `--tailscale-https`). The service leaves that line in the journal. With `--no-tailscale` the token is not printed.

`environmentFile` and `credentials` must be absolute paths outside `/nix/store`. Credential files are loaded with `LoadCredential` and exported under the attribute name. A `PathChanged` path unit (not `PathExists`) restarts the hub when one of those files changes. Agents inherit the hub environment from when they were spawned; upstream does not re-read it.

To bump the pin, from a checkout:

```sh
nix/update.sh            # latest stable GitHub release
nix/update.sh v0.11.1    # one tag
nix fmt
```

`nix/update.sh` rewrites `nix/sources.nix` from that release's `SHA256SUMS` and from the tag's `deploy/kistack.lock`. It pins the `classic` archives, the ones upstream's own install.sh uses. From the lock it takes the GitHub owner and repository (the comment's `github.com` URL), the `rev`, and the `skills` hash, and it asks Nix for the `fetchFromGitHub` hash of that revision. It needs `curl`, `python3`, and `nix` with flakes enabled.
