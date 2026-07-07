# tvs-stack

This repo's job is to boot the **tvs-be** Django backend and **tvs-fe** React frontend together against a shared MySQL + Redis, sourcing each app from a local worktree the user points at. Useful when iterating on both sides at once.

## The pieces

- `docker-compose.yml` — services: `backend`, `frontend`, `database` (MySQL 8), `redis`, `minio` (+ one-shot `minio-init` that creates buckets and exits — `Exited (0)` is its normal state). `celery` + `flower` live in the optional `celery` profile.
- `start.sh` — wrapper that resolves worktree paths, validates them, and runs `docker compose up`.
- `.env.example` — copy to `.env` to pin worktree paths and port overrides.

## Quick start

```sh
cp .env.example .env          # then edit TVS_BE_PATH and TVS_FE_PATH if not siblings
./start.sh                     # boots BE + FE + MySQL + Redis, tails logs
```

Default worktree paths are `../tvs-be` and `../tvs-fe` relative to this repo.

To point at different worktrees (each git worktree is just another directory):

```sh
./start.sh -b ~/Projects/tvs-be-pr-4737 -f ~/Projects/tvs-fe
```

Other useful invocations:

```sh
./start.sh --celery             # also start celery + flower
./start.sh --build              # force a rebuild
./start.sh -d                   # detached
./start.sh --logs backend       # tail one service
./start.sh --shell backend      # bash into a service
./start.sh --mysql              # mysql shell on the DB
./start.sh --down               # tear down (containers + network, NOT volumes)
```

URLs once up:
- Frontend: http://localhost:3000
- Backend:  http://localhost:8020
- MinIO console: http://localhost:9001 (tvslocal / tvslocal123) — browse uploaded assets
- Flower:   http://localhost:5555 (only with `--celery`)

## Creative/asset uploads (MinIO as local S3)

`/v2/assets/upload_url/` presigns an S3 PUT; without AWS creds it 400s with
`ASSET_STORAGE_PRESIGNED_URL_GENERATION_FAILED_ERROR` (`NoCredentialsError`
under the hood). The stack therefore runs **MinIO** and injects into the
backend/celery env (compose `x-local-s3-env` block): `AWS_ENDPOINT_URL_S3`,
MinIO creds, and local bucket names (`tvs-local-assets`, `tvs-local-icons`,
`tvs-local-vast-input`, plus `tvs-telestream-us-west-2` mirroring the
hardcoded `TELESTREAM_S3_BUCKET`). boto3 honors `AWS_ENDPOINT_URL_S3`
natively — no BE code changes.

How the flow works locally:
1. BE presigns a PUT URL on `http://minio.localhost:${MINIO_PORT:-9000}`. The
   hostname resolves **both** ways: in-network via a compose alias on the
   `minio` service, and in browsers because they resolve `*.localhost` to
   127.0.0.1 (Chrome/Firefox do; plain `curl` does NOT — use
   `--resolve minio.localhost:9000:127.0.0.1` when testing by hand, and add
   an `/etc/hosts` entry if your browser ever doesn't).
2. The browser PUTs the file straight to MinIO.
3. `confirm_upload` head-checks the object, then for non-QC advertisers either
   leaves it in the VAST input bucket (VAST flag on) or downloads the bytes
   and pushes them to **Beeswax** (flag off) — Beeswax never reads the bucket,
   so a local MinIO carries the full flow. Mind which Beeswax domain
   `tvs-be/.env` points at before confirming uploads (sandbox vs prod!).

Caveats:
- **The FE dev server's CSP must allow the MinIO origin.** `tvs-fe/tools/srcServer.js`
  sets a `connect-src` allowlist; without `http://minio.localhost:9000` in it the
  browser blocks the presigned PUT ("violates the following Content Security
  Policy directive: connect-src ..."). Add it next to the `API_URL`
  interpolation (one line; dev-server-only file, CloudFront CSP for deployed
  envs is unaffected). Until that lands upstream in tvs-fe, EACH FE worktree
  needs the edit, and the dev server must be restarted to pick it up.
- **QC (Telestream) cannot run locally** — Telestream Cloud watches the real
  AWS bucket and posts webhooks that can't reach localhost. `seed/seed.sh`
  sets `enable_qc=False` on all advertisers after seeding for this reason
  (create_mock_data seeds them with QC on). A QC-enabled advertiser's upload
  still lands in the local `tvs-telestream-us-west-2` bucket, but its
  creative stays in QC-pending forever.
- Same for VAST transcoding (MediaConvert/SNS) — the upload + creative
  creation work, but no transcode happens locally.
- MinIO data lives in the `minio-data` volume: survives `--down` and
  `--reset-db`, wiped by `--reset` / `down -v`.
- To use **real AWS** instead, delete the `x-local-s3-env` injection from
  docker-compose.yml and put `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/
  `AWS_DEFAULT_REGION` + real bucket names in `tvs-be/.env`.

## Django admin static files (why /admin/ was unstyled)

The backend container runs **both** gunicorn (`:8010`) and **nginx** (`:8020`)
via `start-server.sh`. nginx is the piece that serves `/static` (`root
/opt/app/src`) and proxies `/` → gunicorn. So compose must publish the host
port to **container `:8020` (nginx), not `:8010` (gunicorn)** — hitting
gunicorn directly bypasses nginx, and gunicorn serves no static, so the admin
renders unstyled and `/static/admin/css/base.css` 404s.

Two compose-side pieces make admin CSS work (BE worktree is untouched):
- `ports: "${BACKEND_PORT:-8020}:8020"` — host traffic lands on nginx.
- A `be-static` **named volume** mounted at `/opt/app/src/static`, plus a
  `command` that runs `collectstatic --noinput` before `start-local-server.sh`.
  The `${TVS_BE_PATH}:/opt/app` bind mount shadows the image's build-time
  collectstatic, so we recollect at boot — into a volume (not the
  bind-mounted worktree) to keep the worktree pristine.

Note: `/admin/login/` 302-redirects to `/account/login/` (the django-two-factor
2FA login) — that's app behavior, not a static problem. Get a TOTP code for the
local `qaadmin` user with `./qa-admin-otp.sh`.

## How env / secrets work

**Each worktree's own `.env` is the source of truth.** Compose reads `${TVS_BE_PATH}/.env` and `${TVS_FE_PATH}/.env` via `env_file`. We deliberately do not copy or template these — switching worktrees changes the env you boot against.

So before first run:
- `tvs-be/.env` exists (copy from `tvs-be/.env.example`, fill in `BEESWAX_*`, `OKTA_*`, `DJANGOSECRETKEY`).
- `tvs-fe/.env` exists. `start.sh` will fail fast if either is missing.

`start.sh` overrides a few values that must point at the in-network services:
- `TVSDBHOSTNAME=database`, `TVSDBPORT=3306`, `REDIS_URL=redis://redis:6379` for the backend.
- `API_URL` for the FE defaults to `http://localhost:${BACKEND_PORT}` because the FE bundle executes in your browser, not in the container — so it needs the host port, not the docker network name.

## Seeding the database (why a fresh DB 403s, and how to fix it)

A freshly-migrated DB has **tables but no data**. The Okta token authenticates fine, but the backend looks up `User.objects.get(sso_id=<token uid>, sso_provider=OKTA)` (see `tvsapi/authentication.py`); with no matching row, **every `/v1/...` route returns 403** and `/v1/terms_and_conditions/...` 400s. So after any DB wipe you must re-seed.

Seed with:

```sh
./start.sh --seed <your-okta-sso-id>              # local data only (user/orgs/tenants/T&Cs + fixtures)
./start.sh --seed <your-okta-sso-id> --with-beeswax   # also pull advertisers/campaigns from Beeswax
```

`<your-okta-sso-id>` is the `uid` claim of your bearer token (e.g. decode the JWT, or read it from the admin). You can set `SEED_OKTA_ID` in `tvs-stack/.env` and then just run `./start.sh --seed`.

What `seed/seed.sh` does (mirrors the BE's own `src/setup_local_db.sh`, minus migrate/createsuperuser since the container migrates on boot):
1. `create_mock_data --okta-id <id>` — your app User (with `sso_id`=okta-id, `sso_provider` defaults to OKTA), 2 orgs, 2 tenants, T&Cs, billing.
2. *(only with `--with-beeswax`)* `load_beeswax_account --advertiser-ids all` — pulls advertisers→campaigns→line items→creatives→assets into local MySQL. **Read-only against Beeswax (GETs only); scoped to `BEESWAX_ACCOUNT_ID`.**
3. `loaddata` the BidStrategy/Bundle/AudienceType/Audience fixtures.
4. Links bid strategies + private bundles to all advertisers.

**Not idempotent** — `create_mock_data` does plain `.create()`s that violate unique constraints on a second run. Re-seed only on a fresh DB (`--reset-db` first).

## Connecting to Beeswax — sandbox vs prod (be careful)

The backend talks to Beeswax via `BEESWAX_DOMAIN` / `BEESWAX_USERNAME` / `BEESWAX_PASSWORD` / `BEESWAX_ACCOUNT_ID` in **`tvs-be/.env`**. The domain decides which Beeswax you hit:
- `tvscisbx.api.beeswax.com` — **`sbx` = the real sandbox.** On it, account `2` is "TvScientific Sandbox" (the canonical test account). Sandbox creds are *separate* from prod creds.
- `tvsci.api.beeswax.com` — **no `sbx` = PRODUCTION.** Account `2` there is the live "tvScientific Production" account. Account `3` is "tvSci-prodTestingAccount_LowBudgets" — a test account but still on prod infra. Avoid unless you mean it.

Account *numbers differ between sandbox and prod*, so never copy an account id across domains. To see which accounts a credential can reach (read-only), run in the backend container:

```python
# ./start.sh --shell backend ; cd src ; python manage.py shell
from django.conf import settings; settings.BEESWAX_ACCOUNT_ID = 0   # auth without scoping
from tvsapi.beeswax_client import BeeswaxClient
for a in BeeswaxClient().get(f"{BeeswaxClient().url}/account/").json()["payload"]:
    print(a["account_id"], a["account_name"], a["active"])
```

Auth failures show as `BeeswaxException: Incorrect authentication credentials` — that's a wrong email/password (or wrong domain for those creds), not an account-scoping issue. Don't hammer it; failed auths can lock the account.

## Launching a campaign to the Beeswax sandbox (local E2E)

Building AND launching a full campaign (incl. video + display-retargeting ad groups) against the sandbox needs reference/config data a fresh DB lacks. `seed/seed.sh` now seeds all of it (see that file for the why on each):

- **SimplifiedBidStrategy** rows (migration 0299 runs before the BidStrategy fixture loads, so it no-ops on a fresh DB → the ad-group Bid Strategy tiles are empty and Save is silently disabled with "Please select a bid strategy").
- **TargetingGroups** linked to the top-level InventoryBundles (drive the "Select an inventory option" tiles).
- **InventorySource + a Deal per bundle** (serializer rejects save: "Included bundles must have at least one deal").
- **Bid strategy `delivery_name` remap** `TVS-BIDDER-NONPROD` → `CPM_PACED` (sandbox has no custom bidder → "invalid bidding strategy key: TVS-BIDDER-NONPROD").
- **IP/bot blocklists disabled** on advertisers (they inject `tvsci-222987` / `tvsci-161525` exclusion segments that only exist in prod BW → "Unrecognized segment keys").

The `InventoryBundle` + `RetargetingSegments` fixtures live in **`tvs-stack/seed/fixtures/`** (kept out of the app repo on purpose) and are piped into the container's `loaddata` over stdin by seed.sh. The other fixtures (BidStrategy/Bundle/AudienceType/Audience) are the BE repo's own, loaded from the worktree's `local_db_fixtures/`.

**One thing seed.sh can't set (it's a Django setting, read from `tvs-be/.env` at boot, not the DB):** unset `BEESWAX_BID_MODIFIER_ID` and `BEESWAX_DELIVERY_MODIFIER_ID` in the BE worktree's `.env`. Those point at prod-only BW bid/delivery modifier objects (709/706); with them set, **video** line items using CPM_PACED fail to publish with "CPM_PACED is not enabled for delivery models" / "Max bid is required when bid modifier is set". Comment them out so they default to `None`, then recreate the backend **and** celery to pick it up (`docker compose up -d --force-recreate backend celery` — `restart` does NOT reload `env_file`).

Caveats even when all of the above is done:
- **Campaign/ad-group start dates must not be in the past** (the fixture/mock dates can drift behind the container clock) — the launch blocks with "Start date must not be in the past".
- **Video line items publish but stay PENDING**, not ACTIVE — there's no local video transcoding (MediaConvert), so the video creative never finishes processing and BW won't fully activate the line item. The display (static image) ad group goes ACTIVE. The line item IS created in BW (gets a `beeswax_lid` + `beeswax_teid`); PENDING is expected locally, not a sync failure.
- The line-item sync runs in the **celery** worker, so `./start.sh --celery` (or the celery profile) must be up for launches to reach Beeswax.

## Logging in with your Okta user

There are two layers that need to agree on which Okta tenant to use:
- BE — `OKTA_DOMAIN` / `OKTA_CLIENT_ID` in `tvs-be/.env`.
- FE — `REACT_APP_OKTA_ORG_URL` / `REACT_APP_OKTA_CLIENT_ID` in `tvs-fe/.env`.

`npm run start:livebe` works for the user because both BE *and* FE are pointed at `login.thefinstore.com` with the same client ID `0oacl36ns5RqBYrvX5d5`. To reuse that same Okta user against the **local** backend you booted here, set the FE `.env` to those same Okta values (mirror `tvs-fe/.env.livebe`'s Okta lines) while leaving `API_URL=http://localhost:8020`. That gives you: local BE, local FE, real Okta auth, real Beeswax sandbox — the most common dev loop.

## Logging in with your Okta user (the second question)

There are two layers that need to agree on which Okta tenant to use:
- BE — `OKTA_DOMAIN` / `OKTA_CLIENT_ID` in `tvs-be/.env`.
- FE — `REACT_APP_OKTA_ORG_URL` / `REACT_APP_OKTA_CLIENT_ID` in `tvs-fe/.env`.

`npm run start:livebe` works for the user because both BE *and* FE are pointed at `login.thefinstore.com` with the same client ID `0oacl36ns5RqBYrvX5d5`. To reuse that same Okta user against the **local** backend you booted here, set the FE `.env` to those same Okta values (mirror `tvs-fe/.env.livebe`'s Okta lines) while leaving `API_URL=http://localhost:8020`. That gives you: local BE, local FE, real Okta auth, real Beeswax sandbox — the most common dev loop.

Two modes worth knowing:

1. **Local everything** — FE → local BE → Beeswax sandbox. `API_URL=http://localhost:8020`. Best for full-stack dev.
2. **FE-only against hosted BE** (equivalent to `npm run start:livebe`) — `./start.sh --api-url https://api.thefinstore.com`. Doesn't actually need our BE container; you can stop it (`docker compose stop backend database redis`).

## Resetting the database (full reset flow)

```sh
./start.sh --reset-db -y          # wipe db-data volume, recreate, auto-migrate on boot
# WAIT for migrations to FULLY finish (see gotcha below), then:
./start.sh --seed <okta-id>       # re-seed, or add --with-beeswax
```

- `--reset-db` wipes only the MySQL `db-data` volume (keeps the FE `node_modules` volume and BE image). The backend re-migrates from scratch on the way up.
- `--reset` is the nuke: `down -v` (all volumes) + `build --no-cache backend` + up.
- A reset leaves an **empty** DB → you're back to the 403 state until you `--seed`.

## Gotchas learned the hard way

- **Migrations: wait for ZERO unapplied, not for HTTP.** The BE's `start-server.sh` runs `migrate; gunicorn` with a `;` — so if `migrate` fails or is still running, gunicorn serves anyway and `http://localhost:8020/admin/login/` will respond *while migrations are incomplete*. Don't trust an HTTP check after a reset. Poll instead:
  ```sh
  docker compose exec -T -w /opt/app/src backend python manage.py showmigrations | grep -c '\[ \]'   # want 0
  ```
  A fresh full migrate takes a few minutes (~hundreds of migrations).
- **`showmigrations` can lie: 0 unapplied does NOT mean schema matches code.** It only compares names against `django_migrations` rows. If tables get restored/replaced from a dump of an env with a different schema (or a rollback goes sideways), you get `OperationalError (1054, "Unknown column ...")` on tables whose migrations are all "applied". Diff models vs schema to scope it:
  ```sh
  docker compose exec -T -w /opt/app/src backend python manage.py shell -c '
  from django.apps import apps
  from django.db import connection
  with connection.cursor() as cur:
      cur.execute("SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = DATABASE()")
      db = {}
      for t, c in cur.fetchall(): db.setdefault(t, set()).add(c)
  for m in apps.get_models():
      t = m._meta.db_table
      for f in m._meta.local_fields:
          if t in db and f.column not in db[t]: print(f"{t}.{f.column}")'
  ```
  Small drift → hand-write `ALTER TABLE ... ADD COLUMN` matching the model defs (and `CREATE OR REPLACE VIEW` from the latest `views/migrations` SQL for `view_*` tables). Big drift → `--reset-db`. (Hit 2026-06-03: 12 columns missing — incrementality/experiment fields — with all migrations "applied".)
- **A long-running backend container runs STALE code after a worktree branch switch.** gunicorn loads Python at boot; switching the worktree branch underneath leaves the container serving the old code (which can mask schema drift — see above). Recreate the backend after switching branches.
- **NEVER recreate/restart the backend while it's mid-migration.** MySQL auto-commits DDL, so an interrupted migrate leaves orphan tables with no `django_migrations` row. The next migrate then dies with `(1050, "Table '...' already exists")` and the schema is stuck half-applied (symptom we hit: `Unknown column 'tvsapi_user._uses_looker'`). Fix = `--reset-db` and let migrate finish uninterrupted. Corollary: set Beeswax/env creds **before** the reset, or recreate the backend only *after* migrations report 0 unapplied.
- **`docker compose restart` does NOT reload `env_file`.** After editing a worktree `.env`, use `docker compose up -d --force-recreate backend` (or restart the whole stack) to pick up new values — but only when not mid-migration (above).
- **Don't run from inside a worktree subdir** — `start.sh` must run from `tvs-stack/`; it resolves paths relative to itself.
- **Bare `docker compose` in this dir needs the worktree env.** `start.sh` exports `TVS_BE_PATH`/`TVS_FE_PATH`, but a raw `docker compose ps` won't have them (you'll see `invalid spec: :/app: empty section between colons`). Either go through `start.sh`, set them in `tvs-stack/.env`, or `export` them first.
- **FE node_modules are in a named volume** (`fe-node-modules`) to keep them off the host bind-mount (otherwise alpine-built modules clash with the host's). If you change `package.json`, run `./start.sh --build` or `docker compose run --rm frontend npm install`.
- **First boot is slow** — backend installs all Python deps + collectstatic; FE installs all npm deps. Subsequent boots reuse the cached image / named volume.
- **File watching on macOS** — the FE container runs with `CHOKIDAR_USEPOLLING=true` so webpack picks up edits through the bind mount. Slightly higher CPU; necessary on Docker Desktop.
- **DB data persists** in the `db-data` named volume across `--down`. To nuke it: `./start.sh --reset-db` (or `docker compose down -v`).
- **`local_db_init/` from the BE worktree** is mounted into the MySQL container's init-dir — same as `tvs-be/dev-docker-compose.yml`. So switching BE worktrees can change init SQL on a fresh DB.
- **The backend uses `start-local-server.sh`** which waits for `database:3306` and then runs `gunicorn` (not `python manage.py runserver`). Django auto-reload does NOT work in this mode — code changes are bind-mounted but you need to `docker compose restart backend` to pick up Python code edits. Templates, static, and FE changes hot-reload fine.
- **Port conflicts** — if you already run MySQL/Redis on the host, override `MYSQL_PORT`/`REDIS_PORT` in `.env` (host side only; the in-network services still listen on the canonical ports).
- **Don't commit `.env`** — `.gitignore` covers it. Worktree-side `.env` files are also gitignored in their respective repos.
- **Pre-commit on tvs-be** can fail if you `docker compose exec backend` and run git there — the container doesn't have the hook tooling.

- **Don't run from inside a worktree subdir** — `start.sh` must run from `tvs-stack/`; it resolves paths relative to itself.
- **FE node_modules are in a named volume** (`fe-node-modules`) to keep them off the host bind-mount (otherwise alpine-built modules clash with the host's). If you change `package.json`, run `./start.sh --build` or `docker compose run --rm frontend npm install`.
- **First boot is slow** — backend installs all Python deps + collectstatic; FE installs all npm deps. Subsequent boots reuse the cached image / named volume.
- **File watching on macOS** — the FE container runs with `CHOKIDAR_USEPOLLING=true` so webpack picks up edits through the bind mount. Slightly higher CPU; necessary on Docker Desktop.
- **DB data persists** in the `db-data` named volume across `--down`. To nuke it: `docker compose down -v`.
- **`local_db_init/` from the BE worktree** is mounted into the MySQL container's init-dir — same as `tvs-be/dev-docker-compose.yml`. So switching BE worktrees can change init SQL on a fresh DB.
- **The backend uses `start-local-server.sh`** which waits for `database:3306` and then runs `gunicorn` (not `python manage.py runserver`). Django auto-reload does NOT work in this mode — code changes are bind-mounted but you need to `docker compose restart backend` to pick up Python code edits. Templates, static, and FE changes hot-reload fine.
- **Port conflicts** — if you already run MySQL/Redis on the host, override `MYSQL_PORT`/`REDIS_PORT` in `.env` (host side only; the in-network services still listen on the canonical ports).
- **Don't commit `.env`** — `.gitignore` covers it. Worktree-side `.env` files are also gitignored in their respective repos.
- **Pre-commit on tvs-be** can fail if you `docker compose exec backend` and run git there — the container doesn't have the hook tooling.

## When something breaks

- `./start.sh --logs backend` — first stop.
- `./start.sh --shell backend` then `python src/manage.py shell` — poke around live.
- DB-from-scratch: `docker compose down -v && ./start.sh --build`.
- Stale build: `./start.sh --no-cache` (rebuilds backend image without cache).
- Okta loop-redirect: BE and FE Okta config disagree. Compare the four vars listed in "Logging in with your Okta user."
- **403 on every `/v1/...` call *after* you can log in** (and `/v1/users/me/` 200s with no advertiser header but 403s from the browser): stale advertiser selection. The FE persists the last-selected advertiser in `localStorage['AdvertiserContext']` (`src/providers/CurrentSessionContext.tsx`) and sends it as `X-TVS-AdvertiserContext`. A value carried over from a prod/livebe session (e.g. `828`) won't exist in the sandbox-seeded DB, so the backend 403s. Fix: clear `localStorage` for `localhost:3000` (or just the `AdvertiserContext` key) and reload. Do this whenever you switch a stack between prod/livebe and the local sandbox.

## What this repo intentionally does NOT do

- It doesn't copy or sync env files between worktrees — that belongs in your worktree setup.
- It doesn't manage Python venvs — the BE runs in its container. If you need a host venv (e.g. for IDE intellisense), see `tvs-be/README.md`.
- It doesn't deploy anything. Deployment for both apps is managed elsewhere (ArgoCD / Elastic Beanstalk; see each repo's README).
