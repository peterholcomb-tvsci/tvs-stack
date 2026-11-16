#!/bin/sh
# Install packages that the mounted tvs-be checkout requires but the image lacks.
# The image is built from one checkout, and /opt/app is often a worktree on a
# newer branch, so a new pin would otherwise need a full image rebuild.
# Packages that are already installed are skipped, so this is fast.
set -e
req=/opt/app/requirements.txt
[ -f "$req" ] || exit 0
pip install --no-cache-dir --quiet --disable-pip-version-check -r "$req"
