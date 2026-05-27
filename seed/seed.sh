#!/usr/bin/env bash
# tvs-stack/seed/seed.sh
# Bootstrap a freshly-migrated tvs-be DB with the minimum data the app needs to
# work: an app User linked to your Okta SSO id, orgs/tenants/T&Cs, billing, and
# the standard BidStrategy/Bundle/AudienceType/Audience fixtures.
#
# Mirrors the BE's own src/setup_local_db.sh, minus migrate/createsuperuser
# (the backend container already runs migrations on boot).
#
# Meant to run against a FRESH (just-migrated, empty) DB — e.g. right after
# `./start.sh --reset-db`. It is NOT safe to re-run on an already-seeded DB:
# create_mock_data does plain OrganizationUser/Billing .create()s that violate
# unique constraints on a second run. If you need to re-seed, reset first.
#
# Beeswax advertiser/campaign data is NOT loaded unless you pass --with-beeswax,
# because that hits the live Beeswax API and depends on which account your
# creds are scoped to. See CLAUDE.md ("Connecting to Beeswax").
#
# Normally invoked via:  ./start.sh --seed [okta-id] [--with-beeswax]
# Can also be run directly from the tvs-stack dir once the stack is up.
set -euo pipefail

OKTA_ID=""
WITH_BEESWAX=0
BEESWAX_ADVERTISER_IDS="all"

usage() {
  cat <<'EOF'
Usage: seed/seed.sh [okta-id] [options]

  okta-id                 Okta SSO id to link the seeded app user to. Falls back
                          to $SEED_OKTA_ID (from tvs-stack/.env) if omitted.
      --with-beeswax      Also run load_beeswax_account (live Beeswax GETs).
      --advertiser-ids X  Beeswax advertiser ids to pull (default: all).
                          Only used with --with-beeswax.
  -h, --help              Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-beeswax)   WITH_BEESWAX=1; shift ;;
    --advertiser-ids) BEESWAX_ADVERTISER_IDS="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    -*)               echo "Unknown option: $1" >&2; usage; exit 2 ;;
    *)                OKTA_ID="$1"; shift ;;
  esac
done

# Run from the tvs-stack dir (parent of this script) so docker compose finds
# docker-compose.yml and the worktree paths.
SEED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(dirname "$SEED_DIR")"
cd "$STACK_DIR"

# Pick up paths/SEED_OKTA_ID from .env unless start.sh already exported them.
if [[ -f .env ]]; then set -a; source .env; set +a; fi
: "${TVS_BE_PATH:=../tvs-be}"
: "${TVS_FE_PATH:=../tvs-fe}"
export TVS_BE_PATH TVS_FE_PATH

OKTA_ID="${OKTA_ID:-${SEED_OKTA_ID:-}}"
if [[ -z "$OKTA_ID" ]]; then
  echo "ERROR: no okta-id given and SEED_OKTA_ID not set in tvs-stack/.env." >&2
  echo "       Pass it: ./start.sh --seed <okta-id>" >&2
  exit 1
fi

# The backend container must be up — seeding runs management commands in it.
if ! docker compose ps --status running --services 2>/dev/null | grep -qx backend; then
  echo "ERROR: backend container isn't running. Start the stack first (./start.sh -d)." >&2
  exit 1
fi

run_be() { docker compose exec -T -w /opt/app/src backend python manage.py "$@"; }

echo "==> Seeding local data for okta-id=$OKTA_ID"
run_be create_mock_data --okta-id "$OKTA_ID"

if (( WITH_BEESWAX == 1 )); then
  echo "==> Loading Beeswax account data (advertiser-ids: $BEESWAX_ADVERTISER_IDS)"
  echo "    NOTE: live Beeswax GETs, scoped to BEESWAX_ACCOUNT_ID in tvs-be/.env."
  run_be load_beeswax_account --advertiser-ids $BEESWAX_ADVERTISER_IDS --okta-id "$OKTA_ID"
else
  echo "==> Skipping Beeswax load (pass --with-beeswax to enable)"
fi

echo "==> Loading fixtures (BidStrategy, Bundle, AudienceType, Audience)"
run_be loaddata \
  ./local_db_fixtures/BidStrategy.dump.json \
  ./local_db_fixtures/Bundle.dump.json \
  ./local_db_fixtures/AudienceType.dump.json \
  ./local_db_fixtures/Audience.dump.json

echo "==> Linking bid strategies / private bundles to all advertisers"
run_be shell -c '
from tvsapi.models import Advertiser, BidStrategy, Bundle
all_advertisers = Advertiser.objects.all()
for strategy in BidStrategy.objects.all():
    strategy.advertisers.set(all_advertisers)
for bundle in Bundle.objects.filter(private=True):
    bundle.advertisers.set(all_advertisers)
print(f"linked {BidStrategy.objects.count()} bid strategies, "
      f"{Bundle.objects.filter(private=True).count()} private bundles "
      f"to {all_advertisers.count()} advertisers")
'

echo "==> Seed complete."
