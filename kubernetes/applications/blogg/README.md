# blogg

The blog at **https://blogg.rosenvall.se**: a static Astro site served by nginx-unprivileged. Public, no sign-in.

Source, image build and the deploy script live in [`carnufex/rosenvall-blogg`](https://github.com/carnufex/rosenvall-blogg);
this folder only deploys it.

## Shape

| Workload | What | Reached from |
|---|---|---|
| `blogg` (2 replicas) | nginx-unprivileged 1.31, read-only root, serves the built site, `/healthz`, `/version.txt`, `/rss.xml` | `HTTPRoute/blogg` on `gateway/external` only (`networkpolicy.yaml`) |

- No storage: the site is baked into the image, tag `sha-<git short>` pinned as `tag@digest`.
- Deploy: `deploy/deploy.sh --deploy` in the source repo builds from a clean worktree, pushes the image, rewrites the pin
  in `deployment.yaml`, pushes this repo and waits until `/version.txt` serves the new tag. Rollback: revert that commit.
- Runtime dependencies: none (no outbound calls, no database).

## Secrets

| Secret | Source |
|---|---|
| `blogg-image-pull` | shared registry pull entry (`registry-password` in Bitwarden, same as the other apps) |

## 3 am

- `HomelabDeploymentUnavailable` / `HomelabPodCrashLooping` / `HomelabPodStuckPending` cover namespace `blogg`
  (`homelab-app-alerts.yaml`) → Alertmanager → Slack.
- First look: `kubectl -n blogg get pods,externalsecret,httproute`, then `kubectl -n blogg logs deploy/blogg` (one line
  per request with status, path and duration; nginx errors on stderr).
- `ImagePullBackOff`: `blogg-image-pull` not `SecretSynced`, or the tag was never pushed.
- Site down but pods fine (Cloudflare 530/404): the HTTPRoute (`kubectl -n blogg describe httproute blogg`), then the
  `cloudflare-gateway-routing` skill; dropped traffic: `hubble observe -n blogg --verdict DROPPED`.
