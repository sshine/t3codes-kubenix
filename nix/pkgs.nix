# One nixpkgs for every perSystem module in this flake.
#
# Claude Code is distributed under Anthropic's commercial terms, which nixpkgs
# marks unfree. The predicate names it rather than setting allowUnfree, so a
# second unfree package cannot arrive unnoticed.
{ inputs, ... }:
{
  perSystem =
    { system, lib, ... }:
    {
      _module.args.pkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg: lib.getName pkg == "claude-code";
      };
    };
}
