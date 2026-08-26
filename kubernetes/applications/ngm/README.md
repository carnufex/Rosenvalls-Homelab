# NGM — träna.rosenvall.se

Test environment for NGM (Next Generation Me), a workout-logging SaaS prototype.
Source: `carnufex/NextGenerationMe` → `web/` (Next.js 15, standalone output, SQLite).

- **Host**: `träna.rosenvall.se` (punycode `xn--trna-moa.rosenvall.se` in the HTTPRoute).
  Covered by the wildcard DNS record and wildcard certificate — no Cloudflare changes needed.
- **Image**: `registry.rosenvall.se/carnufex/ngm:sha-<gitshort>` — built locally from
  `NextGenerationMe/web/`, pushed to the self-hosted registry, tag bumped here to deploy.
- **Storage**: SQLite on the `ngm-data` Longhorn PVC (2Gi, RWO) → single replica + Recreate.
- **Secrets** (Bitwarden via ExternalSecrets): `registry-password` (image pull).
  The trainer password lives in the app database and is changed in the app
  (`/t/losenord`). On a FRESH database the seed creates trainer `crille` with the
  default password `ngm-admin` — log in and change it immediately.
- **Auth model**: email/password accounts with self-registration (solo clients work without
  a trainer), trainer login by username or email, personal invite links (`/join/<token>`)
  for trainer-created clients, and optional Google login.

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

Build & deploy:

```
cd NextGenerationMe/web
docker build --platform linux/amd64 -t registry.rosenvall.se/carnufex/ngm:sha-<gitshort> .
docker push registry.rosenvall.se/carnufex/ngm:sha-<gitshort>
# bump the tag in deployment.yaml, commit, push — ArgoCD syncs.
```
