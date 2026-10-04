# T3 Code's server, taken from the stable release archive rather than built.
#
# The archive is self-contained: one Node single-executable ELF, the web client
# it serves, the resource monitor it spawns, and the native modules it dlopens.
# Nothing in it needs a compiler, so the only work here is making its NEEDED
# entries resolve inside the store.
#
# Upstream cuts a nightly most days and a stable every week or so; `version`
# below follows the stable train, which is what `install.sh` picks by default.
{ ... }:
{
  perSystem =
    {
      pkgs,
      system,
      lib,
      ...
    }:
    let
      version = "0.0.45";

      # Release archives are named by Node's platform-arch, not by Nix's system
      # double, and nix/systems.nix admits only these two.
      asset =
        {
          x86_64-linux = {
            arch = "linux-x64";
            hash = "sha256-EFBa50vGpDz6sP3gvwag4NaGL3QDBZG+mUpkDUig1r0=";
          };
          aarch64-linux = {
            arch = "linux-arm64";
            hash = "sha256-kTNZEBfn1HdSX9pmGkbMlSj9YqDEImgHnkNf+zW5Wsk=";
          };
        }
        .${system};
    in
    {
      packages.t3code = pkgs.stdenv.mkDerivation {
        pname = "t3code";
        inherit version;

        src = pkgs.fetchurl {
          url = "https://github.com/pingdotgg/t3code/releases/download/v${version}/t3-${version}-${asset.arch}.tar.gz";
          inherit (asset) hash;
        };

        sourceRoot = "t3-${version}-${asset.arch}";

        nativeBuildInputs = [ pkgs.autoPatchelfHook ];

        # The executable is a Node single-executable: its payload is appended to
        # the ELF and located through the section headers. stdenv strips every ELF
        # it installs, which rewrites those headers and leaves a binary that dies
        # on SIGILL before it prints anything. patchelf itself is harmless here.
        dontStrip = true;

        # Every ELF in the archive needs only libc, libstdc++ and libgcc.
        buildInputs = [ pkgs.stdenv.cc.cc.lib ];

        # ffi-rs ships one shared object per libc. autoPatchelf would try to
        # resolve the musl one against glibc and fail the build over a file the
        # glibc binary never opens.
        preBuild = ''
          rm -rf node_modules/@ff-labs/fff-bin-*-musl
        '';

        # The executable resolves client/, node_modules/ and resource-monitor/
        # from its own realpath, so the tree has to stay together and only the
        # entry point may be linked into bin.
        installPhase = ''
          runHook preInstall
          mkdir -p $out/libexec/t3code $out/bin
          cp -r . $out/libexec/t3code/
          ln -s $out/libexec/t3code/t3 $out/bin/t3
          runHook postInstall
        '';

        # Proves the patching worked and the tree is still self-locating. Writes
        # into a scratch home: the CLI creates its state directory on any run.
        doInstallCheck = true;
        installCheckPhase = ''
          runHook preInstallCheck
          HOME=$(mktemp -d) T3CODE_HOME=$(mktemp -d) $out/bin/t3 --version
          runHook postInstallCheck
        '';

        meta = {
          description = "Open-source control plane for coding agents";
          homepage = "https://t3.codes";
          license = lib.licenses.mit;
          mainProgram = "t3";
          platforms = [
            "x86_64-linux"
            "aarch64-linux"
          ];
          sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
        };
      };
    };
}
