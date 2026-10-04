image := "git.shine.town/infra/t3codes-kubenix/t3node"
charts := "oci://git.shine.town/infra/charts"

_list:
    @just --list --unsorted

# Format every file treefmt knows
fmt:
    treefmt

fmt-check:
    treefmt --fail-on-change --no-cache

# Build the node image (docker-archive tarball) into t3node.tar.gz
build:
    nix build .#image -o t3node.tar.gz

# The tag an image built from the current flake.lock carries
tag:
    #!/usr/bin/env bash
    set -euo pipefail
    t3=$(nix eval --raw .#t3code.version)
    last_modified=$(nix eval --impure --expr \
      '(builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.nixpkgs.locked.lastModified')
    printf '%s-%s\n' "$t3" "$(date -u -d "@${last_modified}" +%Y%m%d)"

# Push the image as :latest and as :<t3-version>-<nixpkgs-date>
push: build
    #!/usr/bin/env bash
    set -euo pipefail
    # SKOPEO_DEST_CREDS ("user:token") is consumed when set; absent means the
    # ambient auth in ~/.config/containers/auth.json.
    args=()
    [ -n "${SKOPEO_DEST_CREDS:-}" ] && args=(--dest-creds "$SKOPEO_DEST_CREDS")
    for t in latest "$(just tag)"; do
      skopeo copy --insecure-policy "${args[@]}" \
        docker-archive:t3node.tar.gz "docker://{{image}}:$t"
    done

# Package the chart and push it to the registry kubenix vendors from
push-chart:
    #!/usr/bin/env bash
    set -euo pipefail
    # REGISTRY_PASSWORD is consumed when set; absent means the ambient auth in
    # helm's own registry config, which is what a push by hand uses. helm push
    # takes no credential flags, so a login has to happen first either way.
    if [ -n "${REGISTRY_PASSWORD:-}" ]; then
      helm registry login git.shine.town -u forgejo_admin -p "$REGISTRY_PASSWORD"
    fi
    out=$(mktemp -d)
    trap 'rm -rf "$out"' EXIT
    helm package chart -d "$out"
    helm push "$out"/t3codes-*.tgz {{charts}}

# Render the chart the way the cluster uses it
render *args:
    helm template t3node ./chart --set fullnameOverride=t3node {{args}}

lint:
    helm lint ./chart

# Assert the chart renders the shapes the cluster asks of it
test-chart:
    #!/usr/bin/env bash
    set -euo pipefail

    fail() { echo "FAIL: $*" >&2; exit 1; }

    # Counts documents rather than matching text: a separator glued to the end of
    # the previous line yields one document where two were meant, and every grep
    # over the text still finds what it looked for.
    render() {
      helm template t3node ./chart -n agentic --set fullnameOverride=t3node "$@"
    }
    kinds() {
      render "$@" | yq -N '[.kind, .metadata.name] | join("/")'
    }

    three=(--set replicaCount=3 --set routes.1=a.example --set routes.2=b.example)

    one=$(kinds)
    [ "$(grep -c '^StatefulSet/' <<< "$one")" = 1 ] || fail "default values render no StatefulSet"
    [ "$(grep -c '^Service/t3node-[0-9]' <<< "$one")" = 1 ] || fail "one replica wants one per-pod Service"
    [ "$(grep -c '^HTTPRoute/' <<< "$one")" = 0 ] || fail "a node is published though no hostname was asked for"

    many=$(kinds "${three[@]}")
    [ "$(grep -c '^Service/t3node-[0-9]' <<< "$many")" = 3 ] || fail "three replicas want three per-pod Services"
    [ "$(grep -c '^HTTPRoute/' <<< "$many")" = 2 ] || fail "two named ordinals want two HTTPRoutes"

    # A route pointing anywhere but at its own ordinal would spread one client's
    # WebSocket over databases that know nothing of each other.
    stray=$(render "${three[@]}" | yq -N \
        'select(.kind == "HTTPRoute")
         | select(.spec.rules[].backendRefs[].name != .metadata.name)
         | .metadata.name')
    [ -z "$stray" ] || fail "HTTPRoute $stray names a backend that is not its own node"

    echo "chart renders ok"

# Assert the image carries what a node relies on, without a container runtime
test-image: build
    #!/usr/bin/env bash
    set -euo pipefail
    # Reads the layer rather than running anything: CI has no docker daemon,
    # and every claim below is about what is in the image rather than how it
    # behaves.
    workdir=$(mktemp -d)
    # The layer preserves the store's read-only modes, so cleanup needs them back.
    trap 'chmod -R u+w "$workdir" 2>/dev/null; rm -rf "$workdir"' EXIT

    # Into a subdirectory: the tarball carries a mode for its own root, which
    # would otherwise land on $workdir and make the listing below unwritable.
    mkdir -p "$workdir/img"
    tar -xf t3node.tar.gz -C "$workdir/img"
    layer=$(find "$workdir/img" -name layer.tar | head -1)
    [ -n "$layer" ] || { echo "no layer.tar in the image" >&2; exit 1; }

    # Two listings: the verbose one carries modes, and the plain one is the only
    # reliable way to ask whether a path exists, because a verbose line for a
    # symlink ends in its target rather than in itself.
    listing="$workdir/listing"
    names="$workdir/names"
    tar -tvf "$layer" > "$listing"
    tar -tf "$layer" > "$names"

    fail() { echo "FAIL: $*" >&2; exit 1; }

    # The entrypoint drops to this uid and the chart's fsGroup matches it.
    tar -xOf "$layer" ./etc/passwd | grep -q '^agent:x:1000:1000:' \
      || fail "no agent:1000 in /etc/passwd"

    # The volume is mounted over /home/agent, but a bare `docker run <cmd>`
    # skips the entrypoint, and TMPDIR has to exist for anything to work.
    grep -qE '^drwxrwxrwx .* \./home/agent/tmp/$' "$listing" || fail "/home/agent/tmp is not writable"
    grep -qE '^drwxrwxrwt .* \./tmp/$' "$listing" || fail "/tmp is not 1777"

    # The init container reads this to decide whether the volume's store matches
    # the image it is about to run.
    grep -qxF './.nix-store-stamp' "$names" || fail "no /.nix-store-stamp in the image"

    for tool in t3 t3-serve seed-nix claude codex opencode playwright git gh nix node bash; do
      # /bin is a tree of symlinks, so the entry reads "./bin/x -> /nix/store/...".
      target=$(sed -n "s|^l.* \./bin/$tool -> ||p" "$listing" | head -1)
      [ -n "$target" ] || fail "$tool missing from /bin"
      # And the target has to be in the image too: a symlink to a store path
      # that was never copied in passes any check on /bin alone, then fails on
      # first use.
      grep -qxF "${target#/}" "$names" \
        || fail "$tool points at $target, which is not in the image"
    done

    # Retargeting playwright-test is what keeps two unused browsers out of every
    # node's volume; a nixpkgs bump that changes its installPhase breaks it
    # silently, and the closure quietly doubles.
    for unwanted in firefox webkit chromium-1; do
      ! grep -qE "nix/store/[^/]*${unwanted}" "$names" \
        || fail "the image carries $unwanted; nix/_playwright.nix no longer retargets"
    done

    echo "image contents ok"

# Every flake check
check: fmt-check lint test-chart
    nix flake check -L
