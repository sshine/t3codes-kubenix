# The two shell scripts the image drops into /bin, kept as .bash files rather
# than Nix strings so an editor treats them as shell. Exposed as packages so
# `nix build .#seed-nix` shows what nix/image.nix installs.
{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.seed-nix = pkgs.runCommandLocal "t3node-seed-nix" { } ''
        install -Dm555 ${./seed-nix.bash} $out/bin/seed-nix
      '';

      packages.t3-serve = pkgs.runCommandLocal "t3node-serve" { } ''
        install -Dm555 ${./serve.bash} $out/bin/t3-serve
      '';
    };
}
