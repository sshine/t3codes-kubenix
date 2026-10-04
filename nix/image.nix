# The agent node image: T3 Code's server, the agent CLIs it drives, a headless
# browser, and nix itself.
#
# Nix is what makes this worth building rather than pulling: an agent in here
# reaches any of nixpkgs through `nix run`, so the baked store carries only what
# a node needs before it has seen a project. Language toolchains are expected to
# arrive from each project's own flake.
#
# dockerTools.buildImage needs no KVM, so this builds on an ordinary CI runner.
{ ... }:
{
  perSystem =
    { config, pkgs, ... }:
    let
      playwright = import ./_playwright.nix { inherit pkgs; };

      # Chromium renders every glyph as a box without these, which makes a
      # screenshot an agent takes useless. fontconfig outside NixOS finds
      # nothing by itself, so the font directories are named here instead.
      fontsConf = pkgs.makeFontsConf {
        fontDirectories = [
          pkgs.dejavu_fonts
          pkgs.liberation_ttf
        ];
      };

      tools = with pkgs; [
        config.packages.t3code

        # The harnesses T3 Code launches as child processes. It finds them on
        # PATH and shows them under Settings -> Providers.
        claude-code
        codex
        opencode

        # Playwright's CLI also carries `run-test-mcp-server`, which is what the
        # agents drive the browser through.
        playwright.playwright-test

        # Rootless (see nixConf below), so no daemon and no nixbld users.
        nix

        git
        git-lfs
        gh
        openssh
        curl
        cacert

        bashInteractive
        bash-completion
        coreutils
        diffutils
        findutils
        gawk
        gnugrep
        gnused
        less
        ncurses
        procps
        which
        file

        gnutar
        gzip
        bzip2
        xz
        zstd

        fd
        jq
        just
        ripgrep
        tree

        # Several harnesses shell out to node and npm for project tooling even
        # though their own executables are self-contained.
        nodejs
      ];

      # filter-syscalls is off because fsGroup sets the setgid bit on every
      # directory of the volume at each mount, the store included, and the
      # filter refuses any chmod that keeps it: a build copying a store
      # directory fails with EPERM. The filter keeps builders from making setuid
      # files that other users could run, and with no build users there are no
      # other users.
      #
      # The in-cluster cache is an nginx proxy in front of cache.nixos.org that
      # passes upstream signatures through, so it needs no key of its own. Keep
      # cache.nixos.org listed after it: an outage there should slow a node down
      # rather than stop it building.
      nixConf = ''
        experimental-features = nix-command flakes
        accept-flake-config = true
        build-users-group =
        filter-syscalls = false
        sandbox = false
        sandbox-fallback = false
        auto-optimise-store = true
        keep-outputs = false
        keep-derivations = false
        min-free = 2147483648
        max-free = 5368709120
        substituters = http://nix-cache.nix-cache.svc.cluster.local:8080 https://cache.nixos.org
        trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
      '';

      # binSh/usrBinEnv satisfy `#!/bin/sh` and `#!/usr/bin/env` shebangs; the
      # NSS files are written in extraCommands rather than pulled from fakeNss.
      rootEnv = pkgs.buildEnv {
        name = "t3node-root-env";
        paths = tools ++ [
          pkgs.dockerTools.binSh
          pkgs.dockerTools.usrBinEnv
          config.packages.seed-nix
          config.packages.t3-serve
        ];
        pathsToLink = [
          "/bin"
          "/etc"
          "/share"
          "/usr"
        ];
      };
    in
    {
      packages.image = pkgs.dockerTools.buildImage {
        name = "t3node";
        tag = "latest";
        copyToRoot = rootEnv;

        # Register the baked closure in /nix/var/nix/db, so once the store is
        # seeded onto the volume nix treats those paths as valid instead of
        # re-fetching the whole closure from a substituter.
        includeNixDB = true;

        # NSS files must be regular files, not fakeNss's store symlinks, or
        # containerd's create-time user lookup rejects them; agent=1000 matches
        # the uid the chart runs as. /etc arrives read-only, so make it writable.
        extraCommands = ''
          mkdir -p root tmp workspace home/agent/tmp etc
          chmod 1777 tmp
          chmod 0777 home/agent home/agent/tmp workspace
          chmod u+w etc
          printf '%s\n' \
            'root:x:0:0:root:/root:/bin/bash' \
            'agent:x:1000:1000:agent:/home/agent:/bin/bash' \
            'nobody:x:65534:65534:nobody:/:/bin/sh' > etc/passwd
          printf '%s\n' \
            'root:x:0:' \
            'agent:x:1000:' \
            'nogroup:x:65534:' > etc/group
          printf 'hosts: files dns\n' > etc/nsswitch.conf
          # /bin's symlinks resolve into the store the volume provides, so the
          # init container has to be able to tell which store this image
          # expects. Written outside /nix, where the mount cannot shadow it.
          printf '%s\n' ${rootEnv} > .nix-store-stamp
        '';

        config = {
          Cmd = [ "/bin/t3-serve" ];
          WorkingDir = "/workspace";
          ExposedPorts."3773/tcp" = { };
          Env = [
            "PATH=/bin"
            "HOME=/home/agent"
            "USER=agent"
            "SHELL=/bin/bash"
            # A nix build writes gigabytes through TMPDIR. Pointing it at the
            # volume keeps that off the node's ephemeral disk, which is shared
            # with every other pod on the machine.
            "TMPDIR=/home/agent/tmp"
            "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
            "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
            "NIX_CONFIG=${nixConf}"
            "T3CODE_HOME=/home/agent/.t3"
            "T3CODE_HOST=0.0.0.0"
            "T3CODE_PORT=3773"
            # The wrappers already point at this; naming it again keeps anything
            # the tests spawn pointing at the same store path.
            "PLAYWRIGHT_BROWSERS_PATH=${playwright.browsers}"
            # The browsers come from the store, so Playwright's check for a
            # distribution it recognises has nothing useful to say.
            "PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true"
            "FONTCONFIG_FILE=${fontsConf}"
          ];
        };
      };

      packages.default = config.packages.image;
    };
}
