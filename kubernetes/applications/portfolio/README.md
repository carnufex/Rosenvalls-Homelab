# portfolio — rosenvall.se

Christopher's portfolio / CV site. Source: <https://github.com/carnufex/rosenvall-portfolio>
(Next.js 16, standalone). Static content, no database, no secrets besides the registry
pull credential.

| What | Value |
|---|---|
| Image | `registry.rosenvall.se/carnufex/portfolio:sha-<short>` (pinned in `deployment.yaml`) |
| Host | `portfolio.rosenvall.se` (staging) → `rosenvall.se` + `www` after approval |
| Exposure | `HTTPRoute` on `gateway/external` (Cloudflare tunnel wildcard) |
| Replicas | 2, RollingUpdate, restricted PSS, read-only root FS |

## Deploy a new version

```powershell
cd C:\Users\Crille\source\repos\rosenvall-portfolio
$sha = git rev-parse --short HEAD
docker build --platform linux/amd64 -t registry.rosenvall.se/carnufex/portfolio:latest -t registry.rosenvall.se/carnufex/portfolio:sha-$sha .
docker push registry.rosenvall.se/carnufex/portfolio --all-tags
# then bump the sha tag in deployment.yaml, commit, push — ArgoCD auto-syncs
```

Apex cut-over: uncomment `rosenvall.se` / `www.rosenvall.se` in `httproute.yaml`. The
Cloudflare tunnel already has an ingress rule for the apex; the apex **DNS record** must exist
in Cloudflare (CNAME → tunnel), which is managed outside this repo.
