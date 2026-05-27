# tvs-stack

One command to boot **tvs-be** + **tvs-fe** together against a shared MySQL + Redis, sourcing each app from a local worktree of your choice.

```sh
cp .env.example .env       # edit TVS_BE_PATH / TVS_FE_PATH if not ../tvs-be and ../tvs-fe
./start.sh                 # boots backend + frontend + db + redis
```

- Frontend: http://localhost:3000
- Backend:  http://localhost:8020

See [CLAUDE.md](./CLAUDE.md) for the full picture — env handling, Beeswax / Okta wiring, common commands, and gotchas.
