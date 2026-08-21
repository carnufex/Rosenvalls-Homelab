---
name: gitops-app-onboarding
description: >-
  Add a new application to the Rosenvalls-Homelab cluster under
  kubernetes/applications/. Use when scaffolding or onboarding a new app/service
  that should become its own ArgoCD application and namespace. Covers the safe
  onboarding order, the three whitelists a new namespace needs, the standard
  manifest set, image/secret/storage conventions, and when it is safe to expose
  the app publicly.
---

# GitOps App Onboarding

Use this when adding a new app under `kubernetes/applications/`.

## How apps become live

- Each top-level directory under `kubernetes/applications/<name>/` is picked up by
  an ArgoCD `ApplicationSet` (`kubernetes/applications/application-set.yaml`) and
  becomes its **own ArgoCD application and namespace**.
- A folder is deployed once it contains a valid `kustomization.yaml`. Nothing
  reaches the cluster until it is **pushed to `origin`**.
- Cilium is managed outside the generic ApplicationSet (since 2026-08-12) — do not
  model platform components as apps; they live under `kubernetes/infrastructure/`.

## A new namespace must be whitelisted in THREE places

Do this in the same commit as the new folder or the app will fail to sync / its
secrets will never materialize:

1. `kubernetes/applications/project.yaml` — add the namespace to the AppProject
   `destinations`.
2. `kubernetes/infrastructure/controllers/external-secrets/cluster-secret-store.yaml`
   — add the namespace to the ClusterSecretStore `conditions`, otherwise every
   `ExternalSecret` in it stays `SecretSyncError`.
3. Only if the app needs a LAN LoadBalancer IP (raw TCP/UDP, IoT push clients):
   `kubernetes/infrastructure/network/cilium/{ip-pool,announce}.yaml` — add the
   namespace to both the IP-pool selector and the L2 announce selector.

## Onboarding order (smallest safe shape first)

1. `ns.yaml` — namespace with pod-security labels (copy an existing app's labels).
2. `kustomization.yaml` — lists resources in apply order (ns first).
3. Runtime manifests (Deployment/Service/PVC/config) — **only after** image names
   and secret names are confirmed.
4. `externalsecret.yaml` for any secrets (pull from Bitwarden via the
   ClusterSecretStore; never commit real secret values). Create the Bitwarden
   entries first with `bws` (see memory `bitwarden-secrets-write-access`).
5. `HTTPRoute` — **last**, only once image, secrets, and health checks are good.
6. A local `README.md` documenting runtime dependencies and secret names.

## Conventions (match the existing apps)

- **Namespace** carries `pod-security.kubernetes.io/{enforce,audit,warn}: baseline`
  labels — copy the block from an existing `ns.yaml`.
- **Images:** pin `tag@sha256:<digest>` (Renovate/Mend manages bumps — see
  `renovate.json`). Own images are built locally and pushed to
  `registry.rosenvall.se/carnufex/<app>` (GitHub Actions is dead — see the global
  CLAUDE.md "Build & deploy"). Tag immutably (`sha-<gitshort>`), never deploy
  `:latest` for pinned apps.
- **Private images** need an image pull secret: copy `ghcr-image-pull-secret.yaml`
  + its ExternalSecret from `gatebound/` or `matplan/` — it is dual-auth for
  `ghcr.io` (read-only legacy) and `registry.rosenvall.se`.
- **Secrets:** use `ExternalSecret` resources, not inline `Secret` data. Bootstrap-
  only / break-glass secrets stay out of Git.
- **Storage:** Longhorn (`longhorn` StorageClass, 2 replicas, `Retain`) only for
  small RWO config/DB volumes — capacity is tight (see memory
  `longhorn-storage-pressure`). Bulk data (media, photos, blobs) goes on the NFS
  exports (media NFS, generic WD-Red NFS) — see `docs/storage-and-backups/`.
- **Routing:** public → `HTTPRoute` on `gateway/external` (`*.rosenvall.se`,
  wildcard cert); internal-only → `gateway/internal` (`*.rosenvall.local`).
  Raw TCP (game servers, IoT) → `Service: LoadBalancer` from the Cilium pool.
- **kustomization.yaml** lists resources in dependency order — namespace and
  config before workloads, workloads before routes.

## Standard manifest set

Reference apps: `immich/` (public images, NFS storage, public + internal routes),
`gatebound/` (private registry images, LB service, ExternalSecrets),
`headlamp/` (minimal internal-only app).

```
ns.yaml
kustomization.yaml
configmap.yaml
externalsecret.yaml
ghcr-image-pull-secret.yaml   # only for private images
<app>-service.yaml
<app>-deployment.yaml
*-pvc.yaml                     # if it needs persistent storage
<app>-httproute.yaml           # last
README.md
```

Minimal `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ns.yaml
  - externalsecret.yaml
  - <app>-service.yaml
  - <app>-deployment.yaml
```

## Don't expose too early

Do **not** add a public `HTTPRoute` until the image runs, secrets resolve, and
health checks pass. When you do, follow the **cloudflare-gateway-routing** skill
(attach to `gateway/external`, `*.rosenvall.se` host). For internal-only tools,
attach to `gateway/internal` and skip the public route entirely.

## After onboarding

- Push to `origin`; watch the new app appear and converge in ArgoCD
  (`kubectl get applications.argoproj.io -n argocd`). Annotate the app with
  `argocd.argoproj.io/refresh=normal` to skip the poll delay.
- If it does not sync or secrets fail, switch to the **cluster-diagnostics** skill
  and walk the chain top-down — the three whitelists above are the usual culprit.
