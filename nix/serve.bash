#!/usr/bin/env bash
# The image's entrypoint: sign the source-control CLIs in, then start the server.
#
# Everything the server itself reads is an environment variable set in the image
# or overridden by the chart. `serve` is the headless form of the command: it
# opens no browser and prints pairing details to the log.
set -euo pipefail

mkdir -p "$TMPDIR" "$T3CODE_HOME"

# T3 Code does not hold source-control credentials of its own: it shells out to
# each forge's CLI and reads whichever logins it finds. So a forge is configured
# here, by handing its CLI a token, rather than in any T3 Code setting. Settings
# -> Source Control shows the result, and "Setup Required" is what it says when
# no CLI on this machine is logged in.
#
# Tokens arrive as environment variables from a Secret. Re-running a login is
# how a rotated token takes effect, so none of this is conditional on being the
# first start.
if [ -n "${FORGEJO_TOKEN:-}" ]; then
  printf '%s' "$FORGEJO_TOKEN" | fj auth add-token --host "$FORGEJO_HOST"
  echo "[t3node] signed in to $FORGEJO_HOST as ${FORGEJO_USER:-unknown}"

  # fj covers the API; cloning and pushing go through git, which needs the token
  # again. The store helper keeps it in a file rather than asking, which nothing
  # here could answer.
  if [ -n "${FORGEJO_USER:-}" ]; then
    host=${FORGEJO_HOST#https://}
    printf 'https://%s:%s@%s\n' "$FORGEJO_USER" "$FORGEJO_TOKEN" "${host%%/*}" >"$HOME/.git-credentials"
    chmod 600 "$HOME/.git-credentials"
    git config --global credential.helper store
  fi
fi

if [ -n "${GH_TOKEN:-}" ]; then
  printf '%s' "$GH_TOKEN" | gh auth login --with-token
  echo "[t3node] signed in to github.com"
fi

# An agent's commits are rejected without these, and the message says only that
# the identity is unknown.
if [ -n "${GIT_AUTHOR_NAME:-}" ]; then
  git config --global user.name "$GIT_AUTHOR_NAME"
fi
if [ -n "${GIT_AUTHOR_EMAIL:-}" ]; then
  git config --global user.email "$GIT_AUTHOR_EMAIL"
fi

exec t3 serve
