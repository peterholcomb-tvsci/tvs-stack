#!/usr/bin/env bash
# tvs-stack/seed/seed-pg-deals.sh
# Seed PG (Programmatic Guaranteed) QA data for one advertiser: a private
# pg_deals bundle + deal + a flat_cpm BidStrategy, so the FE PG bundle picker
# shows a bundle and PG line-item validation is satisfied.
#
# Idempotent. Runs the python body (seed/seed_pg_deals.py) inside the backend
# container via `manage.py shell`, passing config as env vars. The backend
# container must already be up (./start.sh -d).
#
# Usage:
#   seed/seed-pg-deals.sh --advertiser-id 17 [options]
#
#   --advertiser-id N   (required) advertiser to attach the bundle/deal to
#   --count N           how many bundle+deal pairs to create (default 1);
#                       names/deal-ids are numbered when N > 1
#   --bundle-name NAME  default "QA PG Bundle"
#   --deal-id ID        deal id base, default "qa_pg_deal" (items get _1.._N)
#   --ssp-key KEY       default "qa_pg_ssp"
#   --floor-price D     default 5.00 (each item +1.00)
#   --estimated-cpm D   default 12.00 (each item +2.00)
#   --sync-beeswax      also push deal+bundle to live Beeswax (sandbox if creds are)
set -euo pipefail

ADV=""; BUNDLE=""; DEAL=""; SSP=""; FLOOR=""; CPM=""; SYNC=0; COUNT=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --advertiser-id) ADV="$2"; shift 2 ;;
    --count)         COUNT="$2"; shift 2 ;;
    --bundle-name)   BUNDLE="$2"; shift 2 ;;
    --deal-id)       DEAL="$2"; shift 2 ;;
    --ssp-key)       SSP="$2"; shift 2 ;;
    --floor-price)   FLOOR="$2"; shift 2 ;;
    --estimated-cpm) CPM="$2"; shift 2 ;;
    --sync-beeswax)  SYNC=1; shift ;;
    -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
    *)               echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$ADV" ]]; then
  echo "ERROR: --advertiser-id is required." >&2; exit 1
fi

SEED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(dirname "$SEED_DIR")"
cd "$STACK_DIR"
if [[ -f .env ]]; then set -a; source .env; set +a; fi
: "${TVS_BE_PATH:=../tvs-be}"; : "${TVS_FE_PATH:=../tvs-fe}"
export TVS_BE_PATH TVS_FE_PATH

if ! docker compose ps --status running --services 2>/dev/null | grep -qx backend; then
  echo "ERROR: backend container isn't running. Start the stack first (./start.sh -d)." >&2
  exit 1
fi

docker compose exec -T \
  -e PG_ADVERTISER_ID="$ADV" \
  -e PG_COUNT="$COUNT" \
  -e PG_BUNDLE_NAME="${BUNDLE:-QA PG Bundle}" \
  -e PG_DEAL_ID="${DEAL:-qa_pg_deal}" \
  -e PG_SSP_KEY="${SSP:-qa_pg_ssp}" \
  -e PG_FLOOR_PRICE="${FLOOR:-5.00}" \
  -e PG_ESTIMATED_CPM="${CPM:-12.00}" \
  -e PG_SYNC_BEESWAX="$SYNC" \
  -w /opt/app/src backend python manage.py shell < "$SEED_DIR/seed_pg_deals.py"
