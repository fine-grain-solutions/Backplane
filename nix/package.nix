# Official release binaries, not a from-source Bend build.
# The window binary NEEDs libX11 and also dlopens libfreetype.so.6,
# libfontconfig.so.1 and libX11.so.6 (src/gfx/effects/font.c, src/app/effects/win.c).
# autoPatchelf fixes NEEDED entries. runtimeDependencies plus an explicit
# rpath cover the dlopen names. The bin/ wrappers also export LD_LIBRARY_PATH
# without reading it unset (`set -u` safe) and set BACKPLANE_NO_UPDATE.
{
  lib,
  stdenv,
  fetchurl,
  fetchFromGitHub,
  autoPatchelfHook,
  libx11,
  libxcb,
  libxau,
  libxdmcp,
  freetype,
  fontconfig,
  sources ? import ./sources.nix,
}: let
  system = stdenv.hostPlatform.system;
  plat =
    if builtins.hasAttr system sources.platforms
    then sources.platforms.${system}
    else throw "Backplane publishes no release binary for ${system}";
  runtimeLibs = [
    freetype
    fontconfig
    libx11
    libxcb
    libxau
    libxdmcp
  ];
  libPath = lib.makeLibraryPath runtimeLibs;
  # deploy/kistack.lock names the repository and no subpath. The classic
  # archive does not ship kistack/; the hub loads it only from the directory
  # of the running binary (libexec/backplane, beside backplane-serve).
  kistackSrc = fetchFromGitHub {
    owner = sources.kistackOwner;
    repo = sources.kistackRepo;
    rev = sources.kistackRevision;
    hash = sources.kistackHash;
  };
  # @out@ and @libPath@ are filled in during install. A toFile result must
  # not mention a derivation, and ${LD_LIBRARY_PATH:-} must survive `set -u`.
  wrapperFor = name:
    builtins.toFile "backplane-${name}-wrapper" ''
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
    pname = "backplane";
    version = sources.version;

    src = fetchurl {
      inherit (plat) url hash;
      name = "backplane-${sources.version}-${plat.dir}.tar.gz";
    };
    sourceRoot = "backplane-${plat.dir}";

    nativeBuildInputs = [autoPatchelfHook];
    buildInputs = runtimeLibs;
    # dlopen() searches the binary's RUNPATH. These are not all NEEDED.
    runtimeDependencies = runtimeLibs;
    # The bun helpers list the dynamic linker as NEEDED. It is the interpreter,
    # not a library autoPatchelf can add.
    autoPatchelfIgnoreMissingDeps = [
      "ld-linux-x86-64.so.2"
      "ld-linux-aarch64.so.1"
    ];

    inherit libPath;

    dontStrip = true;
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      libexec=$out/libexec/backplane
      mkdir -p "$libexec" "$out/bin" \
        "$out/share/applications" \
        "$out/share/icons/hicolor/scalable/apps" \
        "$out/share/icons/hicolor/256x256/apps" \
        "$out/share/licenses/backplane"

      for b in backplane backplane-serve backplane-browser backplane-step2glb backplane-voice backplane-kipc; do
        if [ -e "$b" ]; then
          cp -a "$b" "$libexec/$b"
          chmod 755 "$libexec/$b"
        fi
      done
      cp -a web "$libexec/web"
      if [ -d licenses ]; then
        cp -a licenses "$out/share/licenses/backplane/licenses"
      fi
      if [ -f LICENSE ]; then
        cp -a LICENSE "$out/share/licenses/backplane/LICENSE"
      fi
      if [ -f backplane.desktop ]; then
        sed "s|^Exec=.*|Exec=$out/bin/backplane|" backplane.desktop > "$out/share/applications/backplane.desktop"
      fi
      # A future archive that already contains kistack/ wins. Otherwise
      # assemble the tree scripts/build-kistack.sh writes: skills/, LICENSE,
      # our plugin.json, and REVISION. The hub refuses the directory without
      # .claude-plugin/plugin.json.
      if [ -d kistack ]; then
        cp -a kistack "$libexec/kistack"
      else
        src=${kistackSrc}
        rev=${sources.kistackRevision}
        want=${sources.kistackSkills}
        if [ ! -d "$src/skills" ]; then
          echo "kistack: no skills/ at $rev" >&2
          exit 1
        fi
        if [ -n "$(find "$src/skills" -type l -print -quit)" ]; then
          echo "kistack: symlinks in skills/ at $rev: refusing" >&2
          exit 1
        fi
        got=$(
          cd "$src" && find skills -type f | LC_ALL=C sort | while IFS= read -r f; do
            printf '%s  %s\n' "$(sha256sum < "$f" | cut -d' ' -f1)" "$f"
          done | sha256sum | cut -d' ' -f1
        )
        if [ "$got" != "$want" ]; then
          echo "kistack: skills/ at $rev hashes to $got, not $want (deploy/kistack.lock)" >&2
          exit 1
        fi
        mkdir -p "$libexec/kistack/.claude-plugin"
        cp -a "$src/skills" "$libexec/kistack/skills"
        if [ -f "$src/LICENSE" ]; then
          cp -a "$src/LICENSE" "$libexec/kistack/LICENSE"
        fi
        printf '%s\n' '{"name":"kistack","description":"KiStack KiCad skills by American Embedded"}' > "$libexec/kistack/.claude-plugin/plugin.json"
        printf '%s\n' "$rev" > "$libexec/kistack/REVISION"
      fi
      test -s "$libexec/kistack/.claude-plugin/plugin.json"
      test -d "$libexec/kistack/skills"
      if [ -f icon/backplane-desktop.svg ]; then
        cp -a icon/backplane-desktop.svg "$out/share/icons/hicolor/scalable/apps/backplane-desktop.svg"
      elif [ -f icon/backplane.svg ]; then
        cp -a icon/backplane.svg "$out/share/icons/hicolor/scalable/apps/backplane.svg"
      fi
      if [ -f icon/backplane-desktop-256.png ]; then
        cp -a icon/backplane-desktop-256.png "$out/share/icons/hicolor/256x256/apps/backplane-desktop.png"
      elif [ -f icon/backplane-256.png ]; then
        cp -a icon/backplane-256.png "$out/share/icons/hicolor/256x256/apps/backplane.png"
      fi

      test -x "$libexec/backplane"
      test -x "$libexec/backplane-serve"
      substitute ${wrapperFor "backplane"} "$out/bin/backplane" --subst-var out --subst-var libPath
      substitute ${wrapperFor "backplane-serve"} "$out/bin/backplane-serve" --subst-var out --subst-var libPath
      chmod 755 "$out/bin/backplane" "$out/bin/backplane-serve"
      runHook postInstall
    '';

    # autoPatchelf records NEEDED libraries. Append the dlopen directories
    # as well so a RUNPATH lookup finds them even if the hook did not.
    # The classic archive's `backplane` is a shell launcher (it execs
    # backplane-serve beside itself), so patchelf only the ELF binaries.
    postFixup = ''
      for b in backplane backplane-serve; do
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
      updateScript = ./update.sh;
      inherit sources;
    };

    meta = {
      description = "Agentic hardware development, with live KiCad viewers";
      longDescription = ''
        Prebuilt Backplane hub and window from the upstream GitHub release.
        KiStack's skills are installed at libexec/backplane/kistack, beside
        the binary the hub runs, from the revision in deploy/kistack.lock.
        backplane-step2glb embeds OpenCascade (LGPL-2.1); its notices are in
        share/licenses. The package sets BACKPLANE_NO_UPDATE so a packaged
        install does not replace itself from GitHub.
      '';
      homepage = "https://github.com/i2cjak/Backplane";
      license = with lib.licenses; [
        mit
        lgpl21
      ];
      sourceProvenance = with lib.sourceTypes; [binaryNativeCode];
      platforms = builtins.attrNames sources.platforms;
      mainProgram = "backplane";
    };
  }
