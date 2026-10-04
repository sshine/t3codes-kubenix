{ inputs, ... }:
{
  imports = [ inputs.devshell.flakeModule ];

  perSystem =
    { config, pkgs, ... }:
    {
      devshells.default.packages = [
        config.treefmt.build.wrapper
        pkgs.just
        pkgs.skopeo
        pkgs.kubernetes-helm
        pkgs.yq-go
        pkgs.kubectl
      ];
    };
}
