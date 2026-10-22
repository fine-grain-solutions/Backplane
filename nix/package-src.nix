# Backplane built from this checkout, with the same scripts a release uses
# (scripts/build.sh): the web client, backplane-serve, the launcher, and
# KiStack. backplane-kipc is built too (its npm dependencies are fetched
# ahead of time). backplane-browser and backplane-step2glb are not: those
# pull Playwright and OpenCascade, and the hub runs without them.
#
# The native emitter is scripts/native-compiler.py. It refuses to run
# without Bun and otherwise downloads Bend 2.0.36. Both are supplied here:
# baseline Bun from nix/bend.nix, and the codeload archive whose SHA-256
# that script pins, staged into the cache the script already knows how to
# reuse. KiStack is the same fetchFromGitHub pin as nix/package.nix
# (nix/sources.nix); build-kistack.sh only curls when that tarball is absent.
#
# No Google sign-in (BACKPLANE_GOOGLE_BAKE=0). The laws job is not rerun
# (BACKPLANE_SKIP_CHECK=1). Emit peaks near 8 GB.
{
  lib,
  stdenv,
  llvmPackages_19,
  bend,
  python3,
  patch,
  git,
  procps,
  cacert,
  unzip,
  autoPatchelfHook,
  fetchurl,
  fetchFromGitHub,
  writeShellScriptBin,
  writeText,
  libx11,
  libxcb,
  libxau,
  libxdmcp,
  alsa-lib,
  freetype,
  fontconfig,
  src,
  version,
  commit ? "",
  jobs ? 2,
  sources ? import ./sources.nix,
}: let
  runtimeLibs = [
    freetype
    fontconfig
    libx11
    libxcb
    libxau
    libxdmcp
    alsa-lib
  ];
  libPath = lib.makeLibraryPath runtimeLibs;
  bun = bend.passthru.bun-baseline;
  # scripts/native-compiler.py SOURCE_SHA256 for the codeload tag archive.
  bendArchive = fetchurl {
    url = "https://codeload.github.com/bendlang/bend/tar.gz/refs/tags/v2.0.36";
    hash = "sha256-y81vS3WJegUGWHLvrJuNQ1laRnEYMxRh6xuSQpueFok=";
  };
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
  # (the native emitter, `bun build`, `bun --version`).
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
  prepareCompiler = writeText "prepare-compiler.py" ''
    import importlib.util
    import os
    from pathlib import Path
    path = Path("scripts/native-compiler.py").resolve()
    spec = importlib.util.spec_from_file_location("native_compiler", path)
    mod = importlib.util.module_from_spec(spec)
    mod.__file__ = str(path)
    spec.loader.exec_module(mod)
    cache = Path(os.environ["XDG_CACHE_HOME"]) / "backplane-bend/compiler"
    mod.prepare(cache, archive=Path(os.environ["BEND_SOURCE_ARCHIVE"]))
  '';
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
  llvmPackages_19.stdenv.mkDerivation {
    pname = "backplane-src";
    inherit version src;

    nativeBuildInputs = [
      bend
      bunWrap
      python3
      patch
      git
      procps
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
      # build-app.sh asks git where .env lives. An empty repo answers, and
      # there is no .env (BACKPLANE_GOOGLE_BAKE=0).
      git init -q

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

      export BEND_SOURCE_ARCHIVE=${bendArchive}
      python3 ${prepareCompiler}

      rm -rf tools/kipc/node_modules
      cp -a ${kipcDeps}/node_modules tools/kipc/node_modules

      # The hub runs without these. Their installs are Playwright and
      # OpenCascade, which this package does not fetch.
      printf '%s\n' '#!/bin/sh' 'echo "backplane-src: skipping backplane-browser"' > scripts/build-browser.sh
      printf '%s\n' '#!/bin/sh' 'echo "backplane-src: skipping backplane-step2glb"' > scripts/build-step2glb.sh
      chmod +x scripts/build-browser.sh scripts/build-step2glb.sh
      patchShebangs scripts

      export CC=clang
      export BACKPLANE_VERSION=v${version}
      export BACKPLANE_GOOGLE_BAKE=0
      export BACKPLANE_SKIP_CHECK=1
      export BACKPLANE_OBJ_CACHE=0
      export BACKPLANE_EMIT_CACHE=0
      export BACKPLANE_EMIT_REMOTE=0
      export BACKPLANE_CPUS=""
      export BACKPLANE_JOBS=${toString jobs}
      export BP_BUILD_LOCKED=1
      # 8 GiB. build-app.sh keeps a value that is already set.
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

    # autoPatchelf records NEEDED libraries. Append the dlopen directories
    # as well. The launcher is a shell script (deploy/backplane-launch.sh),
    # so patchelf only the ELF binaries.
    postFixup = ''
      for b in backplane backplane-serve backplane-kipc backplane-voice; do
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
        with scripts/build.sh. KiStack is the revision in nix/sources.nix,
        installed at libexec/backplane/kistack beside the binary. The package
        sets BACKPLANE_NO_UPDATE. Google sign-in is not baked in.
        backplane-kipc is included. backplane-browser and backplane-step2glb
        are not.
      '';
      homepage = "https://github.com/i2cjak/Backplane";
      license = lib.licenses.mit;
      platforms = ["x86_64-linux"];
      mainProgram = "backplane";
    };
  }
