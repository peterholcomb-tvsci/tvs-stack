# tvs-stack

One command to boot the **tvs-be** (Django) backend and **tvs-fe** (React) frontend together
against a shared MySQL + Redis + local S3 (MinIO). Each app is sourced from a local
worktree you point at, so you can iterate on both sides at once.

```
┌────────────┐     ┌──────────┐
│  tvs-fe    │ ──► │  tvs-be  │ ──► MySQL · Redis · MinIO (local S3)
│ :3000      │     │  :8020   │ ──► Beeswax sandbox (real, over the network)
└────────────┘     └──────────┘
```

This repo only *wires the services together*. The application code lives in the two
sibling repos; you check those out separately and this stack mounts them in.

---

## 1. Prerequisites

- **Docker runtime**: Either **Colima** (recommended for macOS) or **Docker Desktop**
  - **Colima** (lighter, faster):
    ```sh
    brew install colima docker docker-credential-helper-ecr
    colima start --cpu 4 --memory 8 --network-address
    ```
  - **Docker Desktop**: Install and make sure it's running
- Local clones of **tvs-be** and **tvs-fe**. By default they're expected as siblings of
  this repo (`../tvs-be`, `../tvs-fe`); you can point elsewhere (see step 3).
- **Each app needs its own `.env`** — this stack does *not* create them for you:
  - `tvs-be/.env` — copy from `tvs-be/.env.example`, fill in `BEESWAX_*`, `OKTA_*`,
    `DJANGOSECRETKEY`. Point `BEESWAX_DOMAIN` at the **sandbox** (`tvscisbx.api.beeswax.com`)
    unless you have a reason not to.
  - `tvs-fe/.env` — copy from `tvs-fe/.env.example` (or mirror `tvs-fe/.env.livebe`'s Okta
    lines to reuse your existing Okta user). Leave `API_URL=http://localhost:8020` to talk
    to the local backend.

  `start.sh` fails fast with a clear message if either `.env` is missing.

## 2. First run

```sh
cp .env.example .env     # then edit if your worktrees aren't ../tvs-be and ../tvs-fe
./start.sh               # boots backend + frontend + MySQL + Redis + MinIO, tails logs
```

The **first boot is slow** — the backend installs Python deps + collects static, and the
frontend installs all npm deps. Later boots reuse the cached image and named volumes.

## 3. Seed the database (required before you can log in)

A fresh DB has tables but **no data**, so every `/v1/...` call returns 403 even after you
authenticate. Seed it once the stack is up:

```sh
./start.sh --seed <your-okta-sso-id>                 # local data (user/orgs/tenants/T&Cs + fixtures)
./start.sh --seed <your-okta-sso-id> --with-beeswax  # also pull advertisers/campaigns from Beeswax
```

Your **Okta SSO id** is the `uid` claim of your bearer token (decode the JWT, or read the
"Sso id" field on your user in any nonprod admin). Set `SEED_OKTA_ID` in `.env` and you can
then just run `./start.sh --seed`.

> Re-seeding is **not idempotent** — only seed a fresh DB. To start over:
> `./start.sh --reset-db -y`, wait for migrations to finish, then `--seed` again.

## 4. Open it

- **Frontend:** http://localhost:3000  (log in with Okta)
- **Backend:**  http://localhost:8020
- **MinIO console:** http://localhost:9001  (`tvslocal` / `tvslocal123`) — browse uploaded assets
- **Flower:** http://localhost:5555  (only with `--celery`)

If you get a 403 on every request right after logging in, it's usually a **stale advertiser
selection** carried over from a prod/livebe session — clear `localStorage` for
`localhost:3000` and reload. (See CLAUDE.md → "When something breaks".)

---

## Common commands

| Command | What it does |
| --- | --- |
| `./start.sh` | Boot the stack, tail logs |
| `./start.sh -d` | Boot detached |
| `./start.sh -b ~/path/tvs-be -f ~/path/tvs-fe` | Point at specific worktrees |
| `./start.sh --celery` | Also start celery + flower (needed for campaign launches) |
| `./start.sh --build` | Force a rebuild |
| `./start.sh --logs backend` | Tail one service's logs |
| `./start.sh --shell backend` | Open a shell in a service |
| `./start.sh --mysql` | MySQL shell on the database |
| `./start.sh --seed <okta-id>` | Seed a fresh DB (add `--with-beeswax` for Beeswax data) |
| `./start.sh --down` | Stop containers + network (keeps volumes / data) |
| `./start.sh --reset-db -y` | Wipe the DB volume and replay migrations (then re-seed) |
| `./start.sh --reset` | Full nuke: all volumes + rebuild backend image |
| `./qa-admin-otp.sh` | Print a 2FA code for the local `qaadmin` Django admin user |

`./start.sh --help` lists everything.

## Local overrides

`docker-compose.yml` is the shared, checked-in definition. If you need machine-specific
tweaks, put them in a **`docker-compose.override.yml`** — Docker Compose auto-loads it and
it's gitignored, so your changes stay local and don't affect anyone else.

A ready-made one is provided for a **faster/simpler boot** (gunicorn directly on `:8020`,
no nginx, no collectstatic — note this leaves the Django admin unstyled):

```sh
cp docker-compose.override.yml.example docker-compose.override.yml   # opt in
```

## Troubleshooting

### Colima port forwarding issues

If containers are running but `curl http://localhost:8020` fails (connection refused or empty reply):

**Restart Colima with proper networking:**
```sh
docker compose down
colima stop
colima start --cpu 4 --memory 8 --network-address
docker compose up -d
```

The `--network-address` flag fixes port forwarding from the VM to your Mac. Without it, containers can run fine internally but be unreachable from your host.

**If that doesn't work, try QEMU instead of VZ:**
```sh
colima delete -f
colima start --cpu 4 --memory 8 --vm-type qemu
```

QEMU has more reliable networking but is slightly slower than VZ (Apple Virtualization Framework).

**Check if Colima is running:**
```sh
colima status
```

### Backend "Empty reply from server"

If `curl http://localhost:8020` connects but returns an empty reply, nginx might not be installed in the container. The workaround is already applied in `docker-compose.yml` — we connect directly to gunicorn on port 8010 via the host port 8020. Django admin CSS will be missing but the app is functional.

### Frontend can't be reached

Check if the port is actually published:
```sh
docker compose ps  # Look for 0.0.0.0:3000->3000 in PORTS column
docker compose logs frontend --tail 20  # Should show "webpack compiled successfully"
```

If webpack compiled but you can't reach it, it's a Colima port forwarding issue (see above).

### Connection refused on all ports

Colima VM isn't running or port forwarding failed:
```sh
colima status  # Should show "running"
colima stop && colima start --cpu 4 --memory 8 --network-address
```

## Where to go deeper

[**CLAUDE.md**](./CLAUDE.md) is the full field guide — env/secrets handling, MinIO/S3 asset
uploads, Beeswax sandbox-vs-prod safety, Okta login modes, launching a campaign to the
sandbox, and every gotcha learned the hard way. It's written for both humans and for Claude
working in this repo; read the "Working in this repo" section first.
