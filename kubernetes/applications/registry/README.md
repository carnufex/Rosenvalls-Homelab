# registry — self-hosted container registry (registry.rosenvall.se)

CNCF Distribution (`registry:3`) replacing ghcr.io for all homelab-built
images. Motivation: GitHub Actions is billing-blocked account-wide (jobs never
start, not even on self-hosted runners), which froze deploys for every
CI-built app. Publishing is now **local docker build + push** — GitHub remains
git hosting only. GHCR stays readable and keeps the old images as permanent
rollback.

## Architecture

- **One pod** (`registry:3.1.1`), Longhorn PVC `registry-data` (50Gi, RWO →
  `strategy: Recreate`).
- **Dedicated LAN IP `192.168.1.225`** via Cilium LB-IPAM (`io.cilium/lb-ipam-ips`),
  announced by the L2 policy. The `registry` namespace is whitelisted in
  `infrastructure/network/cilium/{ip-pool,announce}.yaml` — keep those in sync.
- **DNS**: grey-cloud (DNS-only) A record `registry.rosenvall.se → 192.168.1.225`
  in the Cloudflare zone. The specific record beats the proxied `*.rosenvall.se`
  wildcard → LAN clients reach the LAN IP directly; the internet resolves an
  RFC1918 address (effectively LAN-only). Deliberately NOT behind the internal
  gateway (private CA) nor the external gateway (Cloudflare tunnel ~100MB
  request cap kills layer pushes; the registry is cluster-recovery infra and
  must not depend on the gateway stack).
- **TLS**: real Let's Encrypt cert (`Certificate/registry-tls`,
  `ClusterIssuer/letsencrypt-prod`, dns01) terminated in the pod → Docker
  Desktop and Talos need zero trust configuration. Distribution does not
  hot-reload certs; the `registry-cert-reload` CronJob restarts the deployment
  Mondays 05:00 (staleness ≤7d, LE overlap 30d).
- **Auth**: htpasswd (bcrypt), user `homelab`, from Bitwarden via ExternalSecret.

## Bitwarden Secrets Manager entries

| Entry | Content | Used by |
|---|---|---|
| `registry-htpasswd` | output of `docker run --rm httpd:2.4 htpasswd -Bbn homelab '<pw>'` | registry pod (`/auth/htpasswd`) |
| `registry-password` | the plaintext password | pull-secret templates in every app ns, `docker login`, `REGISTRY_HTTP_SECRET` |

UUIDs are referenced in `externalsecret.yaml` and in each app's
`*-image-pull` ExternalSecret (dual-auth: `ghcr.io` + `registry.rosenvall.se`).

## Rules

- **Every digest-pinned mirror must carry a tag** (`pinned-<first8>`), e.g.
  `crane copy ghcr.io/carnufex/x@sha256:abc... registry.rosenvall.se/carnufex/x:pinned-abc12345`.
  The weekly GC runs `--delete-untagged=true` and would collect bare manifests.
- Mirroring MUST use `crane copy` / `skopeo copy --all` (digest-preserving) —
  never `docker pull` + `docker push` (re-serializes manifests → new digest,
  breaks `@sha256:` pins).
- GC (Sun 04:30) runs while the registry serves; don't push during that window.
  If corruption is ever suspected: scale deploy to 0, run the GC job manually,
  scale back (the "paranoid variant").

## Publishing workflow (per app)

```powershell
docker build -t registry.rosenvall.se/carnufex/<app>:latest -t registry.rosenvall.se/carnufex/<app>:sha-<git> .
docker push registry.rosenvall.se/carnufex/<app> --all-tags
kubectl -n <ns> rollout restart deployment/<app>   # for :latest refs
# or: bump the tag/digest in this repo and let ArgoCD roll it out
```

## Rollback

Old images remain on ghcr.io and every pull secret still contains the ghcr.io
auth. Reverting an app = git revert of its image-ref commit. Nothing else.
