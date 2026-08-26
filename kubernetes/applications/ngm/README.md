# NGM — träna.rosenvall.se

Test environment for NGM (Next Generation Me), a workout-logging SaaS prototype.
Source: `carnufex/NextGenerationMe` → `web/` (Next.js 15, standalone output, SQLite).

- **Host**: `träna.rosenvall.se` (punycode `xn--trna-moa.rosenvall.se` in the HTTPRoute).
  Covered by the wildcard DNS record and wildcard certificate — no Cloudflare changes needed.
- **Image**: `registry.rosenvall.se/carnufex/ngm:sha-<gitshort>` — built locally from
  `NextGenerationMe/web/`, pushed to the self-hosted registry, tag bumped here to deploy.
- **Storage**: SQLite on the `ngm-data` Longhorn PVC (2Gi, RWO) → single replica + Recreate.
- **Secrets** (Bitwarden via ExternalSecrets): `registry-password` (image pull),
  `ngm-admin-password` → env `NGM_ADMIN_PASSWORD` (trainer login `crille`, seeded on first boot).
- **Auth model**: trainers log in with username/password; clients use personal invite links
  (`/join/<token>`) created from the trainer dashboard.

Build & deploy:

```
cd NextGenerationMe/web
docker build --platform linux/amd64 -t registry.rosenvall.se/carnufex/ngm:sha-<gitshort> .
docker push registry.rosenvall.se/carnufex/ngm:sha-<gitshort>
# bump the tag in deployment.yaml, commit, push — ArgoCD syncs.
```
