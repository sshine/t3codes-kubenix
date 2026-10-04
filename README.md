# t3codes-kubenix

[T3 Code](https://t3.codes) agent nodes for the
[kubenix cluster](../kubenix-cluster). Two artifacts come out of this repository:

- **`git.shine.town/infra/t3codes-kubenix/t3node`** — the node image, built by
  `nix/image.nix`. T3 Code's server, the agent CLIs it launches, a headless
  browser, and nix itself.
- **`oci://git.shine.town/infra/charts/t3codes`** — the chart in `chart/`, which
  runs those nodes as a StatefulSet. kubenix vendors it through `charts.toml`
  and configures it in `services/t3codes.nix`.

The flake is [dendritic](https://flake.parts): every `.nix` file under `nix/` is
a flake-parts module, imported by `import-tree`. Files prefixed with `_` are
plain functions and are skipped.

## Build

```sh
just build        # the image, as a docker-archive tarball
just test-image   # assert its contents, without a container runtime
just render       # the chart, the way the cluster uses it
just check        # formatting, chart lint, nix flake check
```

CI builds and pushes both on every push to `main`. A chart version that already
exists in the registry is rejected, so publishing a chart means bumping
`chart/Chart.yaml`.

## What a node is

T3 Code splits into a server that runs the agents, git and the terminals, and
thin clients over one WebSocket. This image is the server half. A client lists
each server as an *environment*, picks one per thread, and can spread new
threads across them.

Servers are peers, not replicas. Each owns a SQLite database, its worktrees and
its agent sign-ins on a volume of its own, so three nodes are a StatefulSet with
`volumeClaimTemplates` and a Service per pod, never a Deployment at three
replicas. One behind a Service would scatter a client's WebSocket across three
unrelated databases.

## Why nix is in the image

An agent that can run `nix run nixpkgs#<anything>` needs no toolchain baked in,
so the image carries only what a node needs before it has seen a project: the
harnesses, git, a browser, and a shell. Language toolchains are expected to come
from each project's own flake.

That costs the one piece of machinery in here that is not obvious. The store has
to keep its real location at `/nix`, because a `store = <path>` anywhere else is
a diverted store, which nix builds in only through a chroot an unprivileged pod
cannot create. But mounting the volume at `/nix` would shadow the image's baked
store, and with it every symlink in `/bin`, t3 and nix included. So the
`seed-nix` init container copies the baked store onto the volume before the
server starts, and `includeNixDB` registers that closure so the copy is valid
rather than re-fetched.

The copy repeats whenever the image's root environment changes, which
`/.nix-store-stamp` records. Store paths already on the volume are kept, so it
is incremental; the database is replaced, which costs a rebuild of whatever was
built in-pod before the bump.

nix runs rootless: no daemon, no `nixbld` users, no sandbox. `filter-syscalls`
is off because `fsGroup` sets the setgid bit on every directory of the volume at
each mount, the store included, and the filter refuses any chmod that keeps it.

## Why `t3` is unpacked rather than built

Upstream publishes a self-contained Node single-executable per platform, so
`nix/t3code.nix` fetches that and patches its interpreter. One thing is not
negotiable there: `dontStrip`. The executable's payload is appended to the ELF
and found through the section headers, and stdenv's strip pass rewrites them
into a binary that dies on SIGILL before printing anything.

## Reaching a node

A browser talks to every environment it is connected to directly, so a node a
browser should reach needs a public hostname of its own. `chart/values.yaml`
takes one per pod ordinal; a node left out is reachable only in-cluster.

Those hostnames carry T3 Code's own bearer auth and nothing else, deliberately.
The client reaches a secondary environment cross-origin, where production CORS
is wildcard-origin with credentials off and no fetch sets `credentials`, so the
request carries a bearer token and no cookies. A cookie proxy in front would
redirect those calls to its identity provider and the browser would discard the
answer. Only the hostname that serves the UI can sit behind oauth2-proxy, and
that is what `services/t3codes.nix` does with `code.shine.town`.

Upstream has no supported way to turn its own auth off behind a trusted proxy;
[discussion #6750](https://github.com/pingdotgg/t3code/discussions/6750) tracks
it, and `unsafe-no-auth` exists in the `ServerAuthPolicy` schema but is never
activated.

To let a browser or phone in, mint a link on the node it should reach:

```sh
kubectl -n agentic exec t3node-0 -- t3 auth pairing create \
    --base-url https://code.shine.town --ttl 30m
```

Open it, and that client is authorized from then on. Links are one-time, so each
new device needs its own.

## Signing the agents in

Each CLI keeps its own credentials under `$HOME`, which is the volume, so a
sign-in survives a restart. Drive them from **Settings → Providers** in the web
UI rather than putting API keys in the pod: that is what makes a Claude Code
subscription work instead of metered billing.

## Known rough edge

The baked store is about 3 GiB on disk and the image about 840 MiB compressed,
and every node copies the whole thing onto its own volume at first start. Most
of it is the three harnesses and the browser, which overlap very little. Cutting
it means moving more of the default set behind project flakes.
