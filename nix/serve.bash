#!/usr/bin/env bash
# The image's entrypoint: start the T3 Code server in the foreground.
#
# Everything the server reads is an environment variable set in the image or
# overridden by the chart, so this exists only to create the two directories a
# fresh volume has not got yet. `serve` is the headless form of the command: it
# opens no browser and prints pairing details to the log.
set -euo pipefail

mkdir -p "$TMPDIR" "$T3CODE_HOME"

exec t3 serve
