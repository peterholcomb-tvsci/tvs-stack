# Seed PG (Programmatic Guaranteed) deals QA data.
#
# Run inside the backend container via `manage.py shell` (Django already set up):
#     docker compose exec -T -w /opt/app/src backend python manage.py shell < seed_pg_deals.py
# Normally invoked through seed/seed-pg-deals.sh, which passes config as env vars.
#
# Creates the minimum data the FE PG bundle picker needs for a given advertiser,
# plus a flat_cpm BidStrategy so PGLineItemRequiresFlatCPMBidStrategy is satisfied.
# The FE call this targets:
#     GET /targeting/inventorybundles/?level=1&private=true&type=pg_deals&cost_model=<m>
# PG_COUNT controls how many bundle+deal pairs are created (default 1); names and
# deal ids are numbered ("QA PG Bundle 1", qa_pg_deal_1, ...).
# Deals are created with always_bid=True to match the platform's PG definition
# (always_bid and not rev_share — see targeting/0056_backfill_always_bid_pg_deals).
# Idempotent. Beeswax sync OFF unless PG_SYNC_BEESWAX=1.
import os
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.db import transaction

from targeting.models.deal import Deal
from targeting.models.inventory_bundle import InventoryBundle
from targeting.models.inventory_source import InventorySource
from targeting.models.fields.bundle_types import InventoryBundleTypes
from tvsapi.models import Advertiser
from tvsapi.models.bid_strategy import BidStrategy

ADVERTISER_ID = int(os.environ["PG_ADVERTISER_ID"])
BUNDLE_NAME = os.environ.get("PG_BUNDLE_NAME", "QA PG Bundle")
DEAL_ID_BASE = os.environ.get("PG_DEAL_ID", "qa_pg_deal").removesuffix("_1")
SSP_KEY = os.environ.get("PG_SSP_KEY", "qa_pg_ssp")
FLOOR_PRICE = Decimal(os.environ.get("PG_FLOOR_PRICE", "5.00"))
ESTIMATED_CPM = Decimal(os.environ.get("PG_ESTIMATED_CPM", "12.00"))
COUNT = int(os.environ.get("PG_COUNT", "1"))
SYNC_BEESWAX = os.environ.get("PG_SYNC_BEESWAX", "0") == "1"


def _log(label, obj, created, **extra):
    verb = "created" if created else "exists"
    extras = " ".join(f"{k}={v}" for k, v in extra.items())
    print(f"  {label}: {verb} id={obj.pk} {extras}".rstrip())


def _seed_pair(advertiser, ssp, index):
    """Create one numbered deal + PG bundle pair for the advertiser."""
    suffix = f" {index}" if COUNT > 1 else ""
    bundle_name = f"{BUNDLE_NAME}{suffix}"
    deal_id = f"{DEAL_ID_BASE}_{index}"
    # vary pricing a little so items are distinguishable in the FE
    floor = FLOOR_PRICE + Decimal(index - 1)
    cpm = ESTIMATED_CPM + Decimal(2 * (index - 1))

    deal, deal_created = Deal.objects.get_or_create(
        supply_source_deal_id=deal_id,
        defaults={
            "name": f"QA PG Deal ({deal_id})",
            "inventory_source": ssp,
            "deal_type": Deal.DealTypes.PG,
            "supported_format": Deal.DealFormats.VIDEO,
            "currency": Deal.Currencies.USD,
            "floor_price": floor,
            "private": True,
            "advertiser": advertiser,
            "always_bid": True,
        },
    )
    if not deal_created:
        updated = False
        for field, value in [
            ("advertiser_id", advertiser.id),
            ("deal_type", Deal.DealTypes.PG),
            ("private", True),
            ("floor_price", floor),
            ("always_bid", True),
        ]:
            if getattr(deal, field) != value:
                setattr(deal, field, value if field != "advertiser_id" else advertiser.id)
                updated = True
        if updated:
            deal.save()
    _log("Deal", deal, deal_created, ext_id=deal.supply_source_deal_id, always_bid=deal.always_bid)

    bundle, bundle_created = InventoryBundle.objects.get_or_create(
        name=bundle_name,
        defaults={
            "display_name": bundle_name,
            "estimated_cpm": cpm,
            "type": InventoryBundleTypes.PG_DEALS,
            "obfuscation_parameter": InventoryBundle.InventoryBundleObfuscationParameters.SEMI_BLIND,
            "format": InventoryBundle.InventoryBundleFormats.VIDEO,
            "private": True,
            "level": 1,
            "deal_list_external_name": f"{bundle_name} (deals)",
        },
    )
    if not bundle_created:
        updated = False
        for field, value in [
            ("type", InventoryBundleTypes.PG_DEALS),
            ("private", True),
            ("level", 1),
            ("format", InventoryBundle.InventoryBundleFormats.VIDEO),
            ("estimated_cpm", cpm),
        ]:
            if getattr(bundle, field) != value:
                setattr(bundle, field, value)
                updated = True
        if updated:
            bundle.save()
    bundle.advertisers.add(advertiser)
    bundle.deal_list.items.add(deal)
    _log("InventoryBundle", bundle, bundle_created, is_pg=bundle.is_pg)

    return deal, bundle


with transaction.atomic():
    advertiser = Advertiser.objects.filter(pk=ADVERTISER_ID).first()
    if not advertiser:
        raise SystemExit(f"Advertiser id={ADVERTISER_ID} not found.")

    ssp, ssp_created = InventorySource.objects.get_or_create(
        external_key=SSP_KEY, defaults={"name": "QA PG SSP"}
    )
    _log("InventorySource", ssp, ssp_created, key=ssp.external_key)

    pairs = [_seed_pair(advertiser, ssp, i) for i in range(1, COUNT + 1)]

    bid_strategy, bs_created = BidStrategy.objects.get_or_create(
        type="flat_cpm", defaults={"display_name": "Flat CPM", "has_event": False}
    )
    bid_strategy.advertisers.add(advertiser)
    _log("BidStrategy", bid_strategy, bs_created)

    visible = InventoryBundle.objects.visible_to(advertiser).filter(
        pk__in=[b.pk for _, b in pairs]
    ).count()
    print(
        "\n=== Seed complete ===\n"
        f"Advertiser: id={advertiser.id} name={advertiser.name!r}\n"
        f"Bundles:    {[(b.id, b.name) for _, b in pairs]}\n"
        f"Deals:      {[(d.id, d.supply_source_deal_id) for d, _ in pairs]}\n"
        f"Visible to advertiser: {visible}/{len(pairs)}\n"
        f"BidStrategy: id={bid_strategy.id} type={bid_strategy.type}\n"
    )

    if SYNC_BEESWAX:
        print("Pushing to Beeswax (sandbox if BEESWAX_DOMAIN=tvscisbx)...")
        from targeting.services.deal import DealService
        from targeting.services.inventory_bundle import InventoryBundleService

        for deal, bundle in pairs:
            DealService.create_update_deal(deal)
            InventoryBundleService.sync_bundle(bundle)
        print("Beeswax sync done.")
    else:
        print("Skipped Beeswax sync (set PG_SYNC_BEESWAX=1 to push deal+bundle to live Beeswax).")

    if get_user_model().objects.count() == 0:
        print(
            "\nWARNING: no User rows exist — FE will 403 every /v1 call until you run "
            "`./start.sh --seed <okta-id>` from tvs-stack to create your Okta-linked User."
        )
