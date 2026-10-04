# Playwright carrying only the browser the agents drive.
#
# nixpkgs' playwright-test bakes the full browser set into its wrapper, so it
# keeps a runtime reference to all of Chromium, Firefox and WebKit no matter
# what PLAYWRIGHT_BROWSERS_PATH says at runtime. Retargeting it here is what
# keeps the image, and the copy of it that lands on every node's PVC, from
# carrying two browsers nothing opens.
#
# withChromium stays false: headless runs reach for the chromium headless shell,
# and headed Chromium is only wanted for `--ui` and codegen, which no pod does.
#
# The agents talk to `playwright run-test-mcp-server`, which ships in this same
# package. The separate playwright-mcp package resolves its browser as
# "chrome-for-testing" and will not fall back to the headless shell, so it would
# drag headed Chromium back in.
#
# Not a flake-parts module: import-tree skips the underscore prefix.
{ pkgs }:
let
  browsers = pkgs.playwright-driver.browsers.override {
    withChromium = false;
    withFirefox = false;
    withWebkit = false;
  };

  playwright-test = pkgs.playwright-test.overrideAttrs (old: {
    installPhase =
      builtins.replaceStrings [ "${pkgs.playwright-driver.browsers}" ] [ "${browsers}" ]
        old.installPhase;
  });
in
{
  inherit browsers playwright-test;
}
