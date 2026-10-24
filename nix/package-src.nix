# Backplane built from this checkout, with the same script a release uses
# (scripts/build.sh): the web client, backplane-serve, the launcher, and
# KiStack. backplane-kipc is built too (its npm dependencies are fetched
# ahead of time). backplane-browser and backplane-step2glb are not: those
# pull Playwright and OpenCascade, and the hub runs without them.
#
# Since upstream's "No C build at all" (32750a4a), the hub is JS on Bun's
# runtime: bend only emits JS (scripts/build-js.sh), there is no
# scripts/native-compiler.py, no C compiler, and dist/backplane is no
# longer a compiled window binary but deploy/backplane-launch.sh, a shell
# launcher that execs backplane-serve (or opens a desktop app / browser tab
# when one is available, neither of which this package installs). The hub
# itself only dlopens libc at run time (src/server/effects/*.js), so no
# X11/ALSA/fontconfig runtime libraries are needed any more; autoPatchelf
# still wires up whatever the Bun-compiled executables actually NEED
# (glibc, libstdc++).
#
# KiStack is the same fetchFromGitHub pin as nix/package.nix (nix/sources.nix);
# build-kistack.sh only curls when that tarball is absent.
#
# No Google sign-in (BACKPLANE_GOOGLE_BAKE=0), no telemetry baked in. The
# laws job is not rerun (BACKPLANE_SKIP_CHECK=1). BACKPLANE_EMIT_CACHE=0
# skips build-js.sh's emit cache, which otherwise keys on `git ls-files`
# (there is no git history inside the sandboxed source). Emit peaks near 8 GB.
{
  lib,
  stdenv,
  bend,
  python3,
  autoPatchelfHook,
  fetchFromGitHub,
  writeShellScriptBin,
  cacert,
  unzip,
  src,
  version,
  commit ? "",
  sources ? import ./sources.nix,
}: let
  runtimeLibs = [stdenv.cc.cc.lib];
  libPath = lib.makeLibraryPath runtimeLibs;
  bun = bend.passthru.bun-baseline;
  kistackSrc = fetchFromGitHub {
    owner = sources.kistackOwner;
    repo = sources.kistackRepo;
    rev = sources.kistackRevision;
    hash = sources.kistackHash;
  };
  kipcManifest = builtins.path {
    name = "kipc-manifest";
    path = ../tools/kipc;
    filter = path: type: let
      base = baseNameOf path;
    in
      (type == "directory" && base != "node_modules")
      || base == "package.json"
      || base == "bun.lock";
  };
  # bun install needs the network. A fixed-output derivation is the only
  # place the sandbox allows it. The main build then skips install.
  kipcDeps = stdenv.mkDerivation {
    pname = "backplane-kipc-deps";
    version = "0";
    src = kipcManifest;
    nativeBuildInputs = [bun cacert unzip];
    outputHashMode = "recursive";
    outputHash = "sha256-x0aftVlV8EoVhFDyXOLCu8pbmfatGMtJRVePZFApuMM=";
    dontConfigure = true;
    dontStrip = true;
    dontFixup = true;
    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR/home
      export BUN_INSTALL_CACHE_DIR=$TMPDIR/bun-cache
      mkdir -p "$HOME" "$BUN_INSTALL_CACHE_DIR"
      bun install --frozen-lockfile
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -a node_modules $out/node_modules
      runHook postInstall
    '';
  };
  # `bun install` in the sandbox has no network. Dependencies are already
  # in tools/kipc/node_modules. Every other invocation is the real binary
  # (bend's emit on Bun, `bun build`, `bun --version`).
  bunWrap = writeShellScriptBin "bun" ''
    if [ "''${1:-}" = "install" ]; then
      if [ -d node_modules ]; then
        exit 0
      fi
      echo "bun install: node_modules is not staged" >&2
      exit 1
    fi
    exec ${bun}/bin/bun "$@"
  '';
  commitStamp =
    if builtins.match "[0-9a-f]{40}" commit != null
    then commit
    else "";
  # @out@ and @libPath@ are filled in during install. A toFile result must
  # not mention a derivation, and ''${LD_LIBRARY_PATH:-} must survive `set -u`.
  wrapperFor = name:
    builtins.toFile "backplane-src-${name}-wrapper" ''
      #!/bin/sh
      set -eu
      export BACKPLANE_NO_UPDATE=1
      if [ -n "''${LD_LIBRARY_PATH:-}" ]; then
        export LD_LIBRARY_PATH=@libPath@:$LD_LIBRARY_PATH
      else
        export LD_LIBRARY_PATH=@libPath@
      fi
      exec @out@/libexec/backplane/${name} "$@"
    '';
in
  stdenv.mkDerivation {
    pname = "backplane-src";
    inherit version src;

    nativeBuildInputs = [
      bend
      bunWrap
      python3
      autoPatchelfHook
    ];
    buildInputs = runtimeLibs;
    runtimeDependencies = runtimeLibs;
    autoPatchelfIgnoreMissingDeps = [
      "ld-linux-x86-64.so.2"
      "ld-linux-aarch64.so.1"
    ];

    dontConfigure = true;
    dontStrip = true;
    inherit libPath;

    buildPhase = ''
      runHook preBuild
      chmod -R u+w .
      export HOME=$TMPDIR/home
      export XDG_CACHE_HOME=$TMPDIR/cache
      mkdir -p "$HOME" "$XDG_CACHE_HOME"

      mkdir -p "$XDG_CACHE_HOME/backplane-bend/kistack-src"
      # Store paths are mode 0555. build-kistack.sh extracts this tarball
      # and removes the work tree on the way out, which fails on those modes.
      kistackStage=$TMPDIR/kistack-stage
      mkdir -p "$kistackStage"
      cp -a ${kistackSrc} "$kistackStage/src"
      chmod -R u+w "$kistackStage/src"
      tar -C "$kistackStage" -czf \
        "$XDG_CACHE_HOME/backplane-bend/kistack-src/${sources.kistackRevision}.tar.gz" \
        src

      rm -rf tools/kipc/node_modules
      cp -a ${kipcDeps}/node_modules tools/kipc/node_modules

      # The hub runs without these. Their installs are Playwright and
      # OpenCascade, which this package does not fetch.
      printf '%s\n' '#!/bin/sh' 'echo "backplane-src: skipping backplane-browser"' > scripts/build-browser.sh
      printf '%s\n' '#!/bin/sh' 'echo "backplane-src: skipping backplane-step2glb"' > scripts/build-step2glb.sh
      chmod +x scripts/build-browser.sh scripts/build-step2glb.sh
      # Only these two stubs need their shebang patched: patching the whole
      # scripts/ tree would rewrite scripts/bend-closure.py's interpreter
      # line and change its sha256, which sidebar-draft-guard.py pins.
      patchShebangs scripts/build-browser.sh scripts/build-step2glb.sh

      export BACKPLANE_VERSION=v${version}
      export BACKPLANE_GOOGLE_BAKE=0
      export BACKPLANE_SKIP_CHECK=1
      # build-js.sh's emit cache keys on `git ls-files`; there is no git
      # history in the sandboxed source, so skip the cache rather than fail.
      export BACKPLANE_EMIT_CACHE=0
      # 8 GiB. build-js.sh keeps a value that is already set.
      export BUN_JSC_forceRAMSize=8589934592
      export BEND_NO_TELEMETRY=1
      ${lib.optionalString (commitStamp != "") ''
        export BACKPLANE_COMMIT_STAMP=${commitStamp}
      ''}
      scripts/build.sh
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      libexec=$out/libexec/backplane
      mkdir -p "$libexec" "$out/bin" \
        "$out/share/applications" \
        "$out/share/icons/hicolor/scalable/apps" \
        "$out/share/icons/hicolor/256x256/apps" \
        "$out/share/licenses/backplane"

      install -m755 dist/backplane-serve "$libexec/backplane-serve"
      install -m755 dist/backplane "$libexec/backplane"
      cp -a dist/web "$libexec/web"
      cp -a dist/kistack "$libexec/kistack"
      for b in backplane-kipc backplane-voice; do
        if [ -e "dist/$b" ]; then
          install -m755 "dist/$b" "$libexec/$b"
        fi
      done
      if [ ! -x "$libexec/backplane-kipc" ]; then
        echo "backplane-src: dist/backplane-kipc was not built" >&2
        exit 1
      fi
      if [ -d dist/licenses ]; then
        cp -a dist/licenses "$out/share/licenses/backplane/licenses"
      fi
      if [ -f LICENSE ]; then
        cp -a LICENSE "$out/share/licenses/backplane/LICENSE"
      fi
      if [ -f deploy/backplane.desktop ]; then
        sed "s|^Exec=.*|Exec=$out/bin/backplane|" deploy/backplane.desktop > "$out/share/applications/backplane.desktop"
      fi
      if [ -f assets/icon/backplane-desktop.svg ]; then
        cp -a assets/icon/backplane-desktop.svg "$out/share/icons/hicolor/scalable/apps/backplane-desktop.svg"
      fi
      if [ -f assets/icon/backplane-desktop-256.png ]; then
        cp -a assets/icon/backplane-desktop-256.png "$out/share/icons/hicolor/256x256/apps/backplane-desktop.png"
      fi

      test -x "$libexec/backplane"
      test -x "$libexec/backplane-serve"
      test -s "$libexec/web/index.html"
      test -s "$libexec/kistack/.claude-plugin/plugin.json"
      test -f "$libexec/kistack/skills/pcb/SKILL.md"
      test "$(tr -d '\n' < "$libexec/kistack/REVISION")" = "${sources.kistackRevision}"
      substitute ${wrapperFor "backplane"} "$out/bin/backplane" --subst-var out --subst-var libPath
      substitute ${wrapperFor "backplane-serve"} "$out/bin/backplane-serve" --subst-var out --subst-var libPath
      chmod 755 "$out/bin/backplane" "$out/bin/backplane-serve"
      runHook postInstall
    '';

    # autoPatchelf records NEEDED libraries. The launcher (dist/backplane)
    # is deploy/backplane-launch.sh, a shell script, so patchelf only the
    # ELF binaries: backplane-serve and the host helpers.
    postFixup = ''
      for b in backplane-serve backplane-kipc backplane-voice; do
        bin="$out/libexec/backplane/$b"
        [ -e "$bin" ] || continue
        if ! old=$(patchelf --print-rpath "$bin" 2>/dev/null); then
          continue
        fi
        if [ -n "$old" ]; then
          patchelf --set-rpath "$old:${libPath}" "$bin"
        else
          patchelf --set-rpath "${libPath}" "$bin"
        fi
      done
    '';

    passthru = {
      inherit sources kistackSrc kipcDeps;
    };

    meta = {
      description = "Backplane built from this checkout";
      longDescription = ''
        Hub, launcher and web client compiled from the flake's own sources
        with scripts/build.sh (the hub is JS on Bun's runtime, no C build).
        KiStack is the revision in nix/sources.nix, installed at
        libexec/backplane/kistack beside the binary. The package sets
        BACKPLANE_NO_UPDATE. Google sign-in is not baked in. backplane-kipc
        is included. backplane-browser and backplane-step2glb are not, and
        there is no desktop app binary (dist/backplane is the upstream
        launcher script, which falls back to the hub when none is installed).
      '';
      homepage = "https://github.com/i2cjak/Backplane";
      license = lib.licenses.mit;
      platforms = ["x86_64-linux"];
      mainProgram = "backplane";
    };
  }
