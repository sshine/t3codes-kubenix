{ inputs, ... }:
{
  imports = [ inputs.treefmt-nix.flakeModule ];

  perSystem =
    { ... }:
    {
      treefmt = {
        projectRootFile = "flake.nix";

        programs.nixfmt.enable = true;
        programs.shfmt.enable = true;
        programs.mdformat.enable = true;
        programs.yamlfmt.enable = true;

        # Helm templates are YAML with Go template directives interleaved, which
        # no YAML formatter can parse.
        settings.global.excludes = [ "chart/templates/*" ];
      };
    };
}
