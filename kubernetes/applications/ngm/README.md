# NGM — träna.rosenvall.se

NGM (Next Generation Me), a private self-hosted workout-logging tool.
Source: `carnufex/NextGenerationMe` → `web/` (Next.js 15, standalone output, Postgres).

- **Host**: `träna.rosenvall.se` (punycode `xn--trna-moa.rosenvall.se` in the HTTPRoute).
  Covered by the wildcard DNS record and wildcard certificate — no Cloudflare changes needed.
- **Image**: `registry.rosenvall.se/carnufex/ngm:sha-<gitshort>@sha256:<digest>` — built from
  `NextGenerationMe/web/` by NGM's CI on every push to main, pinned here by the deployer bot.
- **Database**: CNPG cluster `ngm-postgresql` (2 instances, Postgres 17, `longhorn-critical`,
  `database.yaml`). The app reads `DATABASE_URL` from the CNPG-generated secret
  `ngm-postgresql-app` (key `uri`). Migrated from SQLite 2026-08-28; the old SQLite file
  remains as a cold copy on the `ngm-data` PVC (mount it in a temp pod to read it).
- **Secrets** (Bitwarden via ExternalSecrets): `registry-password` (image pull).
  The trainer password lives in the app database and is changed in the app
  (`/t/losenord`). On a FRESH database the seed creates trainer `crille` with the
  default password `ngm-admin` — log in and change it immediately.
- **Auth model**: email/password accounts with self-registration (solo clients work without
  a trainer), trainer login by username or email, personal invite links (`/join/<token>`)
  for trainer-created clients, and optional Google login.

## Database backups to OneDrive

CronJob `ngm-db-backup` (03:30 Europe/Stockholm) runs `pg_dump --format=custom` and
uploads the dump with rclone to OneDrive under `Rosenvalls-Homelab/ngm/dumps/`
(60-day retention, pruned by the job). The rclone config comes from the same
Bitwarden entry as the Immich backup (`HOMEASSISTANT_RCLONE_CONFIG`) via the
`ngm-onedrive-backup` ExternalSecret. Manual run:
`kubectl -n ngm create job ngm-db-backup-manual --from=cronjob/ngm-db-backup`.

Restore: download the dump, port-forward `svc/ngm-postgresql-rw`, then
`pg_restore --clean --if-exists -d ngm ngm-<stamp>.dump` as the `ngm` user
(password in secret `ngm-postgresql-app`).

## Cron key

CronJob `ngm-polar-sync` (nightly fallback; Polar webhooks are the primary path) calls
`/api/polar/sync-all` with a shared key. The key is the imperative secret `ngm-cron`
(`kubectl -n ngm create secret generic ngm-cron --from-literal=key=<RANDOM>`), exposed to the
app as `NGM_CRON_KEY`. The former trainer-digest CronJob and SMTP secret (`ngm-mail`) were
removed in the 2026-10-20 pivot to a private personal tool.

## Enabling Google login

1. In [Google Cloud Console](https://console.cloud.google.com/apis/credentials): create an
   **OAuth client ID** (type *Web application*). Authorized redirect URI:
   `https://xn--trna-moa.rosenvall.se/auth/google/callback`
   (punycode for träna.rosenvall.se — Google requires the ASCII form). For local dev also
   add `http://localhost:3210/auth/google/callback`.
2. Create the secret (imperative, deliberately outside git):
   `kubectl -n ngm create secret generic ngm-google --from-literal=client-id=<ID> --from-literal=client-secret=<SECRET>`
3. Restart: `kubectl -n ngm rollout restart deployment/ngm`. The "Fortsätt med Google"
   button appears on /login automatically when the env vars are present.

Build & deploy: every push to NGM `main` is deployed by its CI (`.github/workflows/ci.yml`): the
image is built on a GitHub-hosted runner, pushed and cosign-signed from the ARC runner scale set
`ngm-cluster` (`infrastructure/controllers/arc-runners`), and the bot commits
`ngm:sha-<gitshort>@sha256:<digest>` into `deployment.yaml` and `cronjob-polar-sync.yaml`.
By hand (fallback):

```
cd NextGenerationMe/web
docker build --platform linux/amd64 -t registry.rosenvall.se/carnufex/ngm:sha-<gitshort> .
docker push registry.rosenvall.se/carnufex/ngm:sha-<gitshort>
# bump the tag in deployment.yaml, commit, push — ArgoCD syncs.
```
