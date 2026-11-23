#!/bin/sh
# Install packages that the mounted tvs-be checkout requires but the image lacks.
# The image is built from one checkout, and /opt/app is often a worktree on a
# newer branch, so a new pin would otherwise need a full image rebuild.
# Packages that are already installed are skipped, so this is fast.
# --dev also installs requirements-dev.txt (freezegun and other test-only deps).
set -e
install() {
  [ -f "$1" ] || return 0
  pip install --no-cache-dir --quiet --disable-pip-version-check --no-warn-script-location -r "$1"
}
install /opt/app/requirements.txt
if [ "$1" = "--dev" ]; then
  install /opt/app/requirements-dev.txt
fi
