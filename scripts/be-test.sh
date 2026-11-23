#!/bin/sh
# Run tvs-be Django tests in the backend image, against the stack's database.
#
#   scripts/be-test.sh [-b <tvs-be checkout>] <test labels...> [manage.py test flags]
#   scripts/be-test.sh -b ../tvs-be-vercm-2598 tvs_vertical.tests.views.test_campaign_management_filters
#
# -b picks the checkout to mount (default: TVS_BE_PATH from .env). It must be set
# this way: compose mounts TVS_BE_PATH at /opt/app, and an extra `-v` on
# `docker compose run` does not replace that mount.
# Default flags are --noinput --keepdb. Pass --no-keepdb to rebuild the test DB.
set -e
cd "$(dirname "$0")/.."
[ -f .env ] && . ./.env
if [ "$1" = "-b" ]; then
  TVS_BE_PATH=$(cd "$2" && pwd)
  shift 2
fi
[ $# -gt 0 ] || { echo "usage: $0 [-b <tvs-be checkout>] <test labels...>" >&2; exit 2; }
export TVS_BE_PATH
keepdb=--keepdb
for arg in "$@"; do [ "$arg" = "--no-keepdb" ] && keepdb=; done
docker compose up -d --wait database redis >/dev/null
exec docker compose run --rm --no-deps -w /opt/app/src backend \
  sh -c 'sh /opt/stack/sync-be-requirements.sh --dev && exec python manage.py test --noinput '"$keepdb"' "$@"' sh "$@"
