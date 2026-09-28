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

echo "==> Loading BE-repo fixtures (BidStrategy, Bundle, AudienceType, Audience)"
run_be loaddata \
  ./local_db_fixtures/BidStrategy.dump.json \
  ./local_db_fixtures/Bundle.dump.json \
  ./local_db_fixtures/AudienceType.dump.json \
  ./local_db_fixtures/Audience.dump.json

# These two fixtures live in THIS repo (tvs-stack/seed/fixtures), NOT in tvs-be —
# we deliberately keep local-E2E seed data out of the app repo. They aren't on a
# path the backend container can see, so pipe each into loaddata over stdin
# ("loaddata --format=json -" reads one fixture from stdin; run_be already uses -T
# so the redirect below reaches the container).
#   InventoryBundle: without these top-level v2 inventory bundles the wizard's
#     "Select an inventory option" list is empty and no ad group can be completed
#     (blocks Save/Launch). References Country (reference data, present after migrate).
#   RetargetingSegments: "My Data -> Ad Exposure -> Exposed Users (Campaign ID N ...)"
#     groups + segments so the display-retargeting Audience Builder search by
#     Campaign/Ad-Group ID has data. Seeded advertiser-agnostic (global) so they're
#     visible to any advertiser and don't depend on a specific advertiser id existing.
echo "==> Loading tvs-stack local fixtures (InventoryBundle, RetargetingSegments)"
for fx in InventoryBundle RetargetingSegments; do
  run_be loaddata --format=json - < "$SEED_DIR/fixtures/$fx.dump.json"
done

echo "==> Linking bid strategies / private bundles to all advertisers"
run_be shell -c '
from tvsapi.models import Advertiser, BidStrategy, Bundle
all_advertisers = Advertiser.objects.all()
for strategy in BidStrategy.objects.all():
    strategy.advertisers.set(all_advertisers)
for bundle in Bundle.objects.filter(private=True):
    bundle.advertisers.set(all_advertisers)
# Sandbox buzz (tvscisbx) has no TVS-BIDDER-NONPROD custom bidder, so ANY line
# item whose bid strategy delivers as TVS-BIDDER-NONPROD (the outcome/auto
# strategies: max_outcomes, max_roas, max_impressions, auto_bid, ...) fails to
# publish with "invalid bidding strategy key: TVS-BIDDER-NONPROD". Remap them all
# — plus Flat CPM (required for PG) — to the standard native CPM_PACED key so
# campaigns can launch locally. (Outcome optimization is a no-op in the sandbox;
# CPM_PACED just lets Beeswax accept the line item.)
nonprod_renamed = BidStrategy.objects.filter(delivery_name="TVS-BIDDER-NONPROD").update(delivery_name="CPM_PACED")
flat_cpm_renamed = BidStrategy.objects.filter(type="flat_cpm").update(delivery_name="CPM_PACED")
print(f"linked {BidStrategy.objects.count()} bid strategies, "
      f"{Bundle.objects.filter(private=True).count()} private bundles "
      f"to {all_advertisers.count()} advertisers; "
      f"delivery_name -> CPM_PACED (TVS-BIDDER-NONPROD x{nonprod_renamed}, flat_cpm x{flat_cpm_renamed})")
'

# The campaign wizard needs several pieces of reference data that a fresh DB lacks,
# without which no ad group can be built OR launched to the Beeswax sandbox:
#   1. SimplifiedBidStrategy rows — migration 0299 populates these by looking up
#      BidStrategy types, but it runs at container boot BEFORE the BidStrategy
#      fixture is loaded here, so it finds nothing and creates zero rows. Result:
#      the ad-group "Bid Strategy" selector renders no tiles, simplified_bid_strategy
#      stays null, and Save is silently disabled ("Please select a bid strategy").
#      Re-run 0299'"'"'s mapping now that BidStrategy exists.
#   2. TargetingGroups linked to the top-level (level=0) InventoryBundles — the
#      wizard'"'"'s "Select an inventory option" tiles are driven by TargetingGroups
#      (releaseTargetingGroupsApiInventoryTiles); with none, the list is empty.
#   3. An InventorySource + >=1 Deal per included bundle — the serializer rejects
#      save with "Included bundles must have at least one deal."
echo "==> Seeding wizard inventory + simplified bid strategy data (build + launch)"
run_be shell -c '
from decimal import Decimal
from tvsapi.models import BidStrategy, SimplifiedBidStrategy
from targeting.models.inventory_bundle import TargetingGroup, InventoryBundle
from targeting.models.deal import Deal
from targeting.models.inventory_source import InventorySource

# 1. SimplifiedBidStrategy (mirrors migration 0299_populate_simplified_bid_strategy_data,
#    with the 0331 "Manual Bidding" -> "Simple Bidding" rename applied).
sbs_map = [
    ("Cost per Outcome",  "cost_per_outcome", "INTELLIGENT", "Dynamically optimize bidding to minimize Cost per Outcome",  True,  "max_outcomes"),
    ("ROAS",              "roas",             "INTELLIGENT", "Dynamically optimize bidding to maximize Return On Ad Spend", False, "max_roas"),
    ("CPM",               "cpm",              "INTELLIGENT", "Dynamically optimize bidding for lowest Cost per Impression", False, "max_impressions"),
    ("Brand Engagement",  "brand_engagement", "INTELLIGENT", "Dynamically optimize bidding for any outcome",               False, "max_outcomes"),
    ("Simple Bidding",    "manual",           "MANUAL",      "",                                                            False, "auto_bid"),
]
sbs_made = 0
for display_name, type_, category, desc, has_event, orig in sbs_map:
    bs = BidStrategy.objects.filter(type=orig).first()
    if not bs:
        continue
    _, created = SimplifiedBidStrategy.objects.get_or_create(
        type=type_,
        defaults=dict(display_name=display_name, category=category, description=desc,
                      has_event=has_event, original_bid_strategy=bs),
    )
    sbs_made += int(created)

# 2. TargetingGroups + link each to its top-level InventoryBundle (by bundle name).
tg_map = [
    ("max_reach",   "Maximum Reach",       "0001", "Maximum Reach"),
    ("sports",      "Live Sports",         "0002", "Sports Bundle"),
    ("performance", "Maximum Performance", "0003", "Max Performance"),
]
for name, display_name, ordering, bundle_name in tg_map:
    tg, _ = TargetingGroup.objects.get_or_create(
        name=name, defaults=dict(display_name=display_name, ordering=ordering))
    b = InventoryBundle.objects.filter(name=bundle_name, level=0).first()
    if b:
        b.targeting_groups.add(tg)

# 3. InventorySource + one Deal per top-level bundle (bundles must have >=1 deal).
src, _ = InventorySource.objects.get_or_create(
    external_key="tvs-local-ssp", defaults={"name": "tvScientific Local SSP"})
deals_made = 0
for b in InventoryBundle.objects.filter(level=0):
    if b.deal_list_items.exists():
        continue
    deal, created = Deal.objects.get_or_create(
        supply_source_deal_id=f"tvs-local-deal-{b.id}",
        defaults=dict(name=f"Local Deal for {b.name}", inventory_source=src,
                      supported_format=b.format, deal_type=Deal.DealTypes.PMP,
                      private=False, floor_price=Decimal("1.00")),
    )
    b.deal_list_items.add(deal)
    deals_made += int(created)

print(f"SimplifiedBidStrategy +{sbs_made} (total {SimplifiedBidStrategy.objects.count()}); "
      f"TargetingGroups total {TargetingGroup.objects.count()}; "
      f"Deals +{deals_made} on {InventoryBundle.objects.filter(level=0).count()} top-level bundles")
'

# Seeded advertisers come back with enable_qc=True (create_mock_data sets it,
# and load_beeswax_account re-applies it), which routes creative uploads to
# the Telestream QC bucket — but Telestream Cloud can't watch local MinIO or
# call back to localhost, so QC'd uploads would hang forever. Disable QC
# locally (must run LAST, after the Beeswax load): uploads then go to the
# local assets bucket and get pushed straight to Beeswax on confirm.
#
# Also disable the IP/bot blocklists: they append the DS-flagged-IPs
# (TVSCI_DS_FLAGGED_IPS_SEGMENT, tvsci-222987) and flagged-datacenters
# (TVSCI_FLAGGED_DATACENTERS_SEGMENT, tvsci-161525) segments as a NOT(...)
# exclusion on every line item'"'"'s targeting expression. Those segment keys only
# exist in production Beeswax, so with the flags on, launching to the sandbox
# fails with "Unrecognized segment keys: tvsci-161525, tvsci-222987".
echo "==> Disabling QC + IP blocklists on seeded advertisers (not available locally)"
run_be shell -c '
from tvsapi.models import Advertiser
n = Advertiser.objects.update(
    enable_qc=False,
    use_ip_blocklist=False,
    use_ds_powered_ip_blocklist=False,
    use_data_centers_etc_ip_blocklist=False,
)
print(f"enable_qc + IP blocklists disabled on {n} advertisers")
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

# VERCM-2367 order-line picker: the campaign wizard's "Order Line" selector reads
# GET /orders/order-lines/, which returns only lines whose OrderContract.status is
# ACTIVE for the current advertiser. A fresh DB (and the Beeswax load, which doesn't
# touch the orders app) has none, so the picker shows "No active order lines are
# available for this advertiser." Seed one ACTIVE contract per product family and a
# handful of lines under it for EVERY advertiser, so whichever one you demo with has
# selectable CPM (Standard + Managed) and CPA (Managed + Boost) lines. Idempotent:
# keyed by demo-prefixed sfdc_id / lineage_id, so re-running updates in place.
echo "==> Seeding demo order lines (CPM + CPA) for all advertisers"
run_be shell -c '
from datetime import timedelta
from django.utils import timezone
from orders.models import OrderContract, OrderLine
from tvsapi.models import Advertiser

now = timezone.now()
# (product_family, sku, start_offset_days, end_offset_days, budget). Non-overlapping
# windows within a family so lines can be multi-selected without tripping the wizard
# overlap guard; BOOST is exempt from that guard.
LINE_SPECS = [
    (OrderLine.ProductFamily.CPM, OrderLine.Sku.STANDARD, 0,   90,  "50000.00"),
    (OrderLine.ProductFamily.CPM, OrderLine.Sku.MANAGED,  100, 190, "75000.00"),
    (OrderLine.ProductFamily.CPA, OrderLine.Sku.MANAGED,  0,   90,  "60000.00"),
    (OrderLine.ProductFamily.CPA, OrderLine.Sku.BOOST,    0,   90,  "10000.00"),
]

contracts_made = lines_made = 0
for adv in Advertiser.objects.all():
    aid = adv.pk
    contracts = {}
    for family in (OrderLine.ProductFamily.CPM, OrderLine.ProductFamily.CPA):
        # sfdc_id is unique and capped at 18 chars — keep demo ids short.
        contract, created = OrderContract.objects.update_or_create(
            sfdc_id=f"DEMO{family}{aid:0>4}",
            defaults=dict(
                sfdc_opportunity_id=f"DEMOOPP{family}{aid:0>4}",
                contract_number=f"{family}-CONTRACT-{aid}",
                advertiser=adv,
                status=OrderContract.Status.ACTIVE,
                sfdc_modstamp=now,
            ),
        )
        contracts[family] = contract
        contracts_made += int(created)
    for family, sku, start_off, end_off, budget in LINE_SPECS:
        _, created = OrderLine.objects.update_or_create(
            lineage_id=f"DEMO-{family}-{sku}-{aid}",
            defaults=dict(
                # family[-1] distinguishes CPM(M)/CPA(A); both start with C.
                sfdc_id=f"D{family[-1]}{sku[:1]}{aid:0>5}",
                contract=contracts[family],
                advertiser=adv,
                product_family=family,
                sku=sku,
                start_date=now + timedelta(days=start_off),
                end_date=now + timedelta(days=end_off),
                budget=budget,
                sfdc_modstamp=now,
            ),
        )
        lines_made += int(created)
print(f"order lines: +{contracts_made} contracts, +{lines_made} lines across {Advertiser.objects.count()} advertisers")
'

echo "==> Seed complete."
