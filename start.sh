#!/usr/bin/env bash
# tvs-stack: boot tvs-be + tvs-fe + MySQL + Redis from worktrees you point at.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./start.sh [options] [-- extra docker compose args]

  -b, --be PATH       Path to tvs-be worktree   (default: ../tvs-be or $TVS_BE_PATH)
  -f, --fe PATH       Path to tvs-fe worktree   (default: ../tvs-fe or $TVS_FE_PATH)
      --api-url URL   Override API_URL the FE bundle uses
                      (e.g. https://api.thefinstore.com for livebe-style)
      --celery        Also bring up celery + flower (compose profile: celery)
      --build         Force --build on compose up
  -d, --detach        Run detached (default: foreground, tails logs)
      --down          Stop and remove containers + networks (keeps volumes)
      --reset-db      Wipe the MySQL data volume and bring the stack back up.
                      Migrations re-run from a clean DB. Other state (FE
                      node_modules, BE image) is preserved.
      --reset         Full nuke: down -v (all volumes) + rebuild BE image + up.
                      Use when switching between very different worktrees or
                      when --reset-db isn't enough.
      --seed [okta-id]  Seed a freshly-migrated DB (user/orgs/tenants/T&Cs +
                      fixtures) so the app is usable. okta-id falls back to
                      $SEED_OKTA_ID in .env. Stack must be up. See seed/seed.sh.
      --with-beeswax  With --seed: also run load_beeswax_account (live Beeswax
                      GETs, scoped to BEESWAX_ACCOUNT_ID in tvs-be/.env).
      --logs [svc]    Tail logs for all services (or a specific one)
      --shell SVC     Open a shell in a running service (backend, frontend, database, ...)
      --psql / --mysql  Open a MySQL shell on the database container
      --no-cache      Pass --no-cache to docker compose build
  -y, --yes           Skip confirmation prompts (for --reset / --reset-db)
  -h, --help          Show this help

Env you can also set in .env (next to this script):
  TVS_BE_PATH, TVS_FE_PATH, BACKEND_PORT, FRONTEND_PORT, API_URL,
  MYSQL_PORT, REDIS_PORT, FLOWER_PORT, MINIO_PORT, MINIO_CONSOLE_PORT,
  SEED_OKTA_ID.

Examples:
  ./start.sh -b ~/Projects/tvs-be-pr-4737 -f ~/Projects/tvs-fe
  ./start.sh --api-url https://api.thefinstore.com   # FE talks to nonprod, not local BE
  ./start.sh --celery
  ./start.sh --shell backend
  ./start.sh --reset-db -y            # fresh DB, replay all migrations
  ./start.sh --seed 00ug...S5d7       # then re-seed so login works again
  ./start.sh --seed --with-beeswax    # seed + pull Beeswax advertisers
  ./start.sh --reset                  # full nuke, prompts first
EOF
}

# --- option parsing ---
EXTRA_ARGS=()
PROFILES=()
DETACH=0
BUILD=0
NO_CACHE=0
ACTION="up"
SHELL_SVC=""
LOG_SVC=""
FORCE_YES=0
SEED_OKTA_ARG=""
WITH_BEESWAX=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--be)        export TVS_BE_PATH="$2"; shift 2 ;;
    -f|--fe)        export TVS_FE_PATH="$2"; shift 2 ;;
    --api-url)      export API_URL="$2"; shift 2 ;;
    --celery)       PROFILES+=("--profile" "celery"); shift ;;
    --build)        BUILD=1; shift ;;
    --no-cache)     NO_CACHE=1; BUILD=1; shift ;;
    -d|--detach)    DETACH=1; shift ;;
    --down)         ACTION="down"; shift ;;
    --reset-db)     ACTION="reset-db"; shift ;;
    --reset)        ACTION="reset"; shift ;;
    --seed)         ACTION="seed"; SEED_OKTA_ARG="${2:-}"; [[ -n "${SEED_OKTA_ARG}" && "${SEED_OKTA_ARG}" != -* ]] && shift 2 || { SEED_OKTA_ARG=""; shift; } ;;
    --with-beeswax) WITH_BEESWAX=1; shift ;;
    -y|--yes)       FORCE_YES=1; shift ;;
    --logs)         ACTION="logs"; LOG_SVC="${2:-}"; [[ -n "${LOG_SVC}" && "${LOG_SVC}" != -* ]] && shift 2 || shift ;;
    --shell)        ACTION="shell"; SHELL_SVC="${2:?--shell requires a service name}"; shift 2 ;;
    --psql|--mysql) ACTION="mysql"; shift ;;
    -h|--help)      usage; exit 0 ;;
    --)             shift; EXTRA_ARGS+=("$@"); break ;;
    *)              echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load .env in this directory if present (paths/ports/etc).
if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

# Resolve worktree paths — accept relative, normalize to absolute.
: "${TVS_BE_PATH:=../tvs-be}"
: "${TVS_FE_PATH:=../tvs-fe}"
abs_path() { (cd "$1" 2>/dev/null && pwd) || return 1; }

if ! TVS_BE_PATH="$(abs_path "$TVS_BE_PATH")"; then
  echo "ERROR: tvs-be path not found: $TVS_BE_PATH" >&2; exit 1
fi
if ! TVS_FE_PATH="$(abs_path "$TVS_FE_PATH")"; then
  echo "ERROR: tvs-fe path not found: $TVS_FE_PATH" >&2; exit 1
fi
export TVS_BE_PATH TVS_FE_PATH

# Sanity-check the worktrees look right.
[[ -f "$TVS_BE_PATH/Dockerfile" ]] || { echo "ERROR: $TVS_BE_PATH does not look like tvs-be (no Dockerfile)"; exit 1; }
[[ -f "$TVS_FE_PATH/package.json" ]] || { echo "ERROR: $TVS_FE_PATH does not look like tvs-fe (no package.json)"; exit 1; }
[[ -f "$TVS_BE_PATH/.env" ]] || { echo "ERROR: $TVS_BE_PATH/.env not found. Copy from .env.example and fill in BEESWAX_* + OKTA_*."; exit 1; }
[[ -f "$TVS_FE_PATH/.env" ]] || { echo "ERROR: $TVS_FE_PATH/.env not found. Copy from .env.livebe (or .env.example) into .env."; exit 1; }

echo "tvs-stack: BE=$TVS_BE_PATH  FE=$TVS_FE_PATH"
[[ -n "${API_URL:-}" ]] && echo "tvs-stack: API_URL override = $API_URL"

# Apply a local minio-specific patch to the FE worktree if a `git stash`
# entry with "minio" in its message exists. Idempotent: skips if already
# applied, warns (but doesn't fail) if the patch won't apply cleanly.
apply_minio_stash() {
  local stash_ref patch
  stash_ref="$(git -C "$TVS_FE_PATH" stash list 2>/dev/null | grep -i minio | head -1 | cut -d: -f1)"
  if [[ -z "$stash_ref" ]]; then
    return 0
  fi
  patch="$(git -C "$TVS_FE_PATH" stash show -p "$stash_ref" 2>/dev/null)" || return 0
  if printf '%s\n' "$patch" | git -C "$TVS_FE_PATH" apply --reverse --check 2>/dev/null; then
    echo "tvs-stack: minio patch already applied to FE worktree (from $stash_ref)"
    return 0
  fi
  if printf '%s\n' "$patch" | git -C "$TVS_FE_PATH" apply --check 2>/dev/null; then
    printf '%s\n' "$patch" | git -C "$TVS_FE_PATH" apply
    echo "tvs-stack: applied minio patch to FE worktree (from $stash_ref)"
    return 0
  fi
  echo "tvs-stack: WARNING — minio stash $stash_ref doesn't apply cleanly to FE worktree; continuing without it" >&2
}
apply_minio_stash

COMPOSE=(docker compose ${PROFILES[@]+"${PROFILES[@]}"})
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(basename "$SCRIPT_DIR")}"

confirm() {
  (( FORCE_YES == 1 )) && return 0
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

case "$ACTION" in
  up)
    UP_ARGS=()
    (( BUILD == 1 )) && UP_ARGS+=(--build)
    (( DETACH == 1 )) && UP_ARGS+=(-d)
    if (( NO_CACHE == 1 )); then
      "${COMPOSE[@]}" build --no-cache
    fi
    exec "${COMPOSE[@]}" up ${UP_ARGS[@]+"${UP_ARGS[@]}"} ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
    ;;
  down)
    exec "${COMPOSE[@]}" down ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
    ;;
  reset-db)
    if ! confirm "Wipe MySQL data volume '${PROJECT_NAME}_db-data' and replay migrations on a clean DB?"; then
      echo "Aborted."; exit 0
    fi
    "${COMPOSE[@]}" down
    docker volume rm "${PROJECT_NAME}_db-data" 2>/dev/null || echo "(no existing db-data volume — already clean)"
    UP_ARGS=(); (( DETACH == 1 )) && UP_ARGS+=(-d)
    exec "${COMPOSE[@]}" up ${UP_ARGS[@]+"${UP_ARGS[@]}"} ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
    ;;
  reset)
    if ! confirm "FULL NUKE: remove all containers + volumes (db-data AND fe-node-modules) and rebuild the BE image. Continue?"; then
      echo "Aborted."; exit 0
    fi
    "${COMPOSE[@]}" down -v
    "${COMPOSE[@]}" build --no-cache backend
    UP_ARGS=(); (( DETACH == 1 )) && UP_ARGS+=(-d)
    exec "${COMPOSE[@]}" up ${UP_ARGS[@]+"${UP_ARGS[@]}"} ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
    ;;
  seed)
    SEED_ARGS=()
    [[ -n "$SEED_OKTA_ARG" ]] && SEED_ARGS+=("$SEED_OKTA_ARG")
    (( WITH_BEESWAX == 1 )) && SEED_ARGS+=(--with-beeswax)
    exec "$SCRIPT_DIR/seed/seed.sh" ${SEED_ARGS[@]+"${SEED_ARGS[@]}"}
    ;;
  logs)
    if [[ -n "$LOG_SVC" ]]; then
      exec "${COMPOSE[@]}" logs -f "$LOG_SVC"
    else
      exec "${COMPOSE[@]}" logs -f
    fi
    ;;
  shell)
    exec "${COMPOSE[@]}" exec "$SHELL_SVC" /bin/sh -c "command -v bash >/dev/null && exec bash || exec sh"
    ;;
  mysql)
    exec "${COMPOSE[@]}" exec database mysql -uroot -ptvsroot tvs
    ;;
esac
