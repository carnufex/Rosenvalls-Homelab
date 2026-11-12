# mypassion

The talk **Att bygga med agenter / Building with agents** (Sogeti, November 2026) as a static site:
<https://mypassion.rosenvall.se> (public via Cloudflare, Authentik SSO).

Source, image build and the deploy script live in [`carnufex/mypassion`](https://github.com/carnufex/mypassion); this
folder only deploys it. The decks are edited as claude.ai Slides artifacts and synced into that repo.

## Shape

| Workload | What | Reached from |
|---|---|---|
| `mypassion-oauth2-proxy` | oauth2-proxy, Authentik OIDC client `mypassion` (blueprint `apps-mypassion.yaml` in `authentik-runtime`) | `HTTPRoute/mypassion` on `gateway/external` |
| `mypassion` | nginx-unprivileged, read-only root, serves `/sv/`, `/en/`, `/assets/*` (films, range requests) | only oauth2-proxy (`networkpolicy.yaml`) |

- No storage: the deck and films (~90 MB) are baked into the image, tag `sha-<git short>` pinned as `tag@digest`.
- Deploy: `deploy.ps1` in the source repo rewrites the pin in `deployment.yaml`, pushes, waits for the rollout and
  checks `/version.txt` in the pod. Rollback: revert that commit.
- Access: any Authentik user (no group binding). Add a policy binding on the application to narrow it.

## Secrets

| Secret | Source |
|---|---|
| `mypassion-registry` | shared registry pull entries (same as the other apps) |
| `mypassion-oauth2-proxy` | Bitwarden `mypassion-oauth2-client-id`, `-client-secret`, `-cookie-secret` (by name), also projected into `authentik-blueprint-secrets` as `MYPASSION_CLIENT_*` |

## 3 am

- `HomelabDeploymentUnavailable` / `HomelabPodCrashLooping` / `HomelabPodStuckPending` cover namespace `mypassion`
  (`homelab-app-alerts.yaml`) → Alertmanager → Slack.
- Site down but pods fine: `kubectl -n mypassion logs deploy/mypassion-oauth2-proxy` (OIDC errors), then
  `hubble observe -n mypassion --verdict DROPPED`.
- Every request is logged by nginx with the signed-in email: `kubectl -n mypassion logs deploy/mypassion`.
