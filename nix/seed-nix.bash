#!/usr/bin/env bash
# Copy the image's baked /nix onto the volume mounted at /seed, so the server
# container can mount that volume at /nix without the mount shadowing the store
# -- and with it every binary in /bin, including nix and t3 themselves.
#
# Runs as an init container, and re-seeds whenever the image's root environment
# changes: /bin's symlinks come from the image layer while their targets come
# from the volume, so a new image over an already-seeded volume would otherwise
# point every one of them at a store path that is not there.
#
# A silent copy of a few hundred MB looks like a hang in `kubectl logs`, so this
# streams progress:  kubectl logs t3node-0 -c seed-nix -f
set -euo pipefail

dest=/seed
stamp=$(cat /.nix-store-stamp)

if [ "$(cat "$dest/.seeded" 2>/dev/null)" = "$stamp" ]; then
  echo "nix store already seeded for this image -- skipping (fast restart)."
  exit 0
fi

echo "Seeding /nix (~$(du -sh /nix | cut -f1)) onto the volume. Restarts of the same image skip this."

mkdir -p "$dest/store"

(
  while [ ! -e /tmp/.seed-done ]; do
    printf '  ... %s copied\n' "$(du -sh "$dest" 2>/dev/null | cut -f1)"
    sleep 5
  done
) &
progress=$!

# Not `cp -a`: preserving ownership needs root, and this runs as UID 1000.
# --update=none because store paths are immutable, so one already on the volume
# is by definition the wanted content -- and read-only, so it could not be
# written.
cp -dR --preserve=mode,timestamps --update=none /nix/store/. "$dest/store/"
touch /tmp/.seed-done
wait "$progress" 2>/dev/null || true

# The DB, unlike the store, is replaced rather than merged: it has to describe
# the closure of the image now running. Paths built in-pod lose their
# registration and become garbage for nix's next collection -- that costs a
# rebuild after an image bump, never a dangling /bin.
#
# tar, not cp: big-lock and reserved are mode 0600 and owned by root in the
# image, so UID 1000 cannot read them and cp fails the container. nix recreates
# both on demand, and reserved is 8 MiB of zeroes, so neither is worth carrying.
rm -rf "${dest:?}/var"
tar -C /nix -cf - --exclude=var/nix/db/big-lock --exclude=var/nix/db/reserved var |
  tar -C "$dest" -xpf -

# The baked store and DB arrive read-only; nix has to add paths and record them.
chmod u+w "$dest/store"
chmod -R u+w "$dest/var"

printf '%s\n' "$stamp" >"$dest/.seeded"
echo "Seed complete: $(du -sh "$dest" | cut -f1) on the volume."
