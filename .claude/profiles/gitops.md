# GitOps profile — Rosenvalls-Homelab

<!-- Read by gitops-app-onboarding (plugin `gitops@carnufex`, enabled in .claude/settings.json).
     Facts about this cluster only; the method is in the plugin. -->

## Layout

- Apps directory: `kubernetes/applications/` — one folder per app, picked up by
  `kubernetes/applications/application-set.yaml` (each folder becomes its own ArgoCD application and namespace)
- Tracked branch: `master` on `origin`
- Platform components (not apps): `kubernetes/infrastructure/` (its own ApplicationSet). Cilium is managed outside the
  generic ApplicationSet (`kubernetes/infrastructure/cilium-application.yaml`) — do not model platform components as apps.

## Whitelists

1. `kubernetes/applications/project.yaml` — the AppProject `destinations`
2. `kubernetes/infrastructure/controllers/external-secrets/cluster-secret-store.yaml` — the ClusterSecretStore `conditions`
   (otherwise every `ExternalSecret` in the namespace stays `SecretSyncError`)
3. Only for a LAN LoadBalancer IP (raw TCP/UDP, IoT push clients): `kubernetes/infrastructure/network/cilium/ip-pool.yaml`
   and `kubernetes/infrastructure/network/cilium/announce.yaml` — both selectors

## Namespace

- Pod-security labels: `enforce`, `audit` and `warn` all `baseline`, each with `-version: latest` — copy the block from
  `kubernetes/applications/headlamp/ns.yaml`.

## Images

- Own images: `registry.rosenvall.se/carnufex/<app>`, immutable tags `sha-<gitshort>`; pin `tag@sha256:<digest>`. Never
  deploy `:latest` for a pinned app. How to build and push (and the CI path through the ARC runner): the global
  CLAUDE.md, *Build & deploy*.
- Mirroring a third-party image: `crane copy` (digest-preserving), and the digest-pinned artifact carries a `pinned-<first8>`
  tag — weekly GC deletes untagged manifests. Registry docs: `kubernetes/applications/registry/README.md`.
- Pin bumps: Renovate/Mend (`renovate.json`).
- Private images: copy `ghcr-image-pull-secret.yaml` and its ExternalSecret from `kubernetes/applications/gatebound/`; it is
  dual-auth for `ghcr.io` (read-only legacy) and `registry.rosenvall.se`.

## Secrets

- Backend: Bitwarden Secrets Manager (EU), homelab project. Create entries first with `bws` (see the memory
  `bitwarden-secrets-write-access`).
- ClusterSecretStore: `bitwarden-secretsmanager`.
- Bootstrap-only and break-glass secrets stay out of Git.

## Storage

| Class | Use for | Limits |
|---|---|---|
| `longhorn` (2 replicas, `Retain`) | small RWO config and database volumes | capacity is tight — see the memory `longhorn-storage-pressure` |
| media NFS, generic WD-Red NFS exports | bulk data: media, photos, blobs | see `docs/storage-and-backups/` |

## Routing

- Public: `gateway/external` on `*.rosenvall.se` (wildcard Let's Encrypt cert), via Cloudflare
- Internal: `gateway/internal` on `*.rosenvall.local`
- Raw TCP/UDP: `Service: LoadBalancer` from the Cilium pool (needs whitelist 3)

## Reference apps

- `immich/` — public images, NFS storage, public and internal routes
- `gatebound/` — private registry images, LoadBalancer service, ExternalSecrets
- `headlamp/` — minimal internal-only app

## Monitoring

- Generic app alerts: `kubernetes/infrastructure/monitoring/prometheus-stack/homelab-app-alerts.yaml` — add the new
  namespace and deployment to the `namespace=~` and `deployment=~` selectors of `HomelabDeploymentUnavailable`,
  `HomelabPodCrashLooping` and `HomelabPodStuckPending` (and its PVCs to `HomelabPersistentVolumeClaimPending`).
- App-specific rules go in a `PrometheusRule` with label `release: kube-prometheus-stack` in the `monitoring` namespace.
- Alerts reach a person through Alertmanager → Slack (`alertmanager-slack` ExternalSecret); the daily health check also
  posts to Slack.
- Logs: Loki (`kubernetes/infrastructure/monitoring/loki-stack`), queried in Grafana.

## Verify

- `$env:KUBECONFIG = "<repo>\tofu\output\kubeconfig"`
- `kubectl get applications.argoproj.io -n argocd`
- Skip the poll delay: `kubectl -n argocd annotate applications.argoproj.io <app> argocd.argoproj.io/refresh=normal --overwrite`
- `kubectl -n <ns> get externalsecret,pods,httproute`

## Related skills

- Public ingress: `cloudflare-gateway-routing` (project skill)
- Diagnostics: `cluster-diagnostics` (project skill)
