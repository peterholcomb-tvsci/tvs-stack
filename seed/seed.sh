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
# Sandbox buzz (tvscisbx) has no TVS-BIDDER-NONPROD custom bidder; Flat CPM
# (required for PG) must use the standard CPM_PACED key to publish locally.
flat_cpm_renamed = BidStrategy.objects.filter(type="flat_cpm").update(delivery_name="CPM_PACED")
print(f"linked {BidStrategy.objects.count()} bid strategies, "
      f"{Bundle.objects.filter(private=True).count()} private bundles "
      f"to {all_advertisers.count()} advertisers; "
      f"flat_cpm delivery_name -> CPM_PACED ({flat_cpm_renamed} row)")
'

# Seeded advertisers come back with enable_qc=True (create_mock_data sets it,
# and load_beeswax_account re-applies it), which routes creative uploads to
# the Telestream QC bucket — but Telestream Cloud can't watch local MinIO or
# call back to localhost, so QC'd uploads would hang forever. Disable QC
# locally (must run LAST, after the Beeswax load): uploads then go to the
# local assets bucket and get pushed straight to Beeswax on confirm.
echo "==> Disabling QC on seeded advertisers (Telestream can't run locally)"
run_be shell -c '
from tvsapi.models import Advertiser
n = Advertiser.objects.update(enable_qc=False)
print(f"enable_qc=False on {n} advertisers")
'

# Campaigns can only launch when advertiser.billing_account.is_valid() — which
# needs address + secondary-contact fields on the BillingAccount, a CC payment
# profile, AND funding_type_cc_allowed on the org. create_mock_data only wires
# (partial) billing for advertisers that exist at mock time; Beeswax-loaded
# advertisers get none. Must run AFTER load_beeswax_account.
echo "==> Ensuring valid billing accounts on all orgs + advertisers"
run_be shell -c '
from tvsapi.models import Advertiser, Organization, User
from tvsapi.models.billing import BillingAccount, PaymentProfile

contact = User.objects.filter(email="superuser@tvscientific.com").first() or User.objects.first()
filler = {
    "street_address": "100 California St",
    "city": "San Francisco",
    "state": "CA",
    "postal_code": "94111",
    "secondary_contact": "billing-qa@tvscientific.com",
    "secondary_first_name": "QA",
    "secondary_last_name": "Billing",
}

for org in Organization.objects.all():
    if not org.funding_type_cc_allowed:
        org.funding_type_cc_allowed = True
        org.save()
    ba = org.default_billing_account
    if ba is None:
        pp = PaymentProfile.objects.create(
            organization=org, card_number="4242424242424242", card_type="Visa", expiration_date="12/25"
        )
        ba = BillingAccount.objects.create(
            name=f"{org.name}\x27s Billing Account",
            parent_org=org,
            billing_method=BillingAccount.BillingMethod.CC,
            primary_contact=contact,
            default_payment_profile=pp,
        )
        org.default_payment_profile = pp
        org.default_billing_account = ba
        org.save()
    if ba.default_payment_profile is None:
        ba.default_payment_profile = PaymentProfile.objects.create(
            organization=org, card_number="4242424242424242", card_type="Visa", expiration_date="12/25"
        )
    changed = False
    for field, value in filler.items():
        if not getattr(ba, field):
            setattr(ba, field, value)
            changed = True
    if ba.archived:
        ba.archived = False
        changed = True
    if changed or ba.default_payment_profile_id:
        ba.save()
    assert ba.is_valid(), f"BillingAccount {ba.pk} for org {org.pk} still invalid"

linked = 0
for adv in Advertiser.objects.filter(billing_account__isnull=True).select_related("primary_org"):
    if adv.primary_org and adv.primary_org.default_billing_account:
        adv.billing_account = adv.primary_org.default_billing_account
        adv.save()
        linked += 1
print(f"valid billing on {Organization.objects.count()} orgs; linked {linked} advertisers")
'

echo "==> Seed complete."
