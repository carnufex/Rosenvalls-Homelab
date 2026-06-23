---
name: gitops-app-onboarding
description: >-
  Add a new application to the Rosenvalls-Homelab cluster under
  kubernetes/applications/. Use when scaffolding or onboarding a new app/service
  that should become its own ArgoCD application and namespace. Covers the safe
  onboarding order, the standard manifest set, image/secret conventions, and when
  it is safe to expose the app publicly.
---

# GitOps App Onboarding

Use this when adding a new app under `kubernetes/applications/`.

## How apps become live

- Each top-level directory under `kubernetes/applications/<name>/` is picked up by
  an ArgoCD `ApplicationSet` (`kubernetes/applications/application-set.yaml`) and
  becomes its **own ArgoCD application and namespace**.
- A folder is deployed once it contains a valid `kustomization.yaml`. Nothing
  reaches the cluster until it is **pushed to `origin`**.

## Onboarding order (smallest safe shape first)

1. `ns.yaml` — namespace with pod-security labels (copy an existing app's labels).
2. `kustomization.yaml` — lists resources in apply order (ns first).
3. Runtime manifests (Deployment/Service/PVC/config) — **only after** image names
   and secret names are confirmed.
4. `externalsecret.yaml` for any secrets (pull from Bitwarden via the
   ClusterSecretStore; never commit real secret values).
5. `HTTPRoute` — **last**, only once image, secrets, and health checks are good.
6. A local `README.md` documenting runtime dependencies and secret names.

## Conventions (match the existing apps)

- **Namespace** carries `pod-security.kubernetes.io/{enforce,audit,warn}: baseline`
  labels — copy the block from an existing `ns.yaml` (e.g. `bikepal/ns.yaml`).
- **Images:** prefer public, immutable tags or digests over `latest`. For private
  images add a `ghcr-image-pull-secret.yaml`.
- **Secrets:** use `ExternalSecret` resources, not inline `Secret` data. Bootstrap-
  only / break-glass secrets stay out of Git.
- **kustomization.yaml** lists resources in dependency order — namespace and
  config before workloads, workloads before routes.

## Standard manifest set (reference: `kubernetes/applications/bikepal/`)

```
ns.yaml
kustomization.yaml
configmap.yaml
externalsecret.yaml
ghcr-image-pull-secret.yaml   # only for private images
<app>-service.yaml
<app>-deployment.yaml
*-pvc.yaml                     # if it needs persistent storage
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

## MatPlan-specific note

MatPlan needs more than a single image and should stay **scaffold-only** in this
repo until GHCR publishing and a production frontend image exist. Do not wire it
to a public route until those are in place.

## After onboarding

- Push to `origin`; watch the new app appear and converge in ArgoCD.
- If it does not sync or secrets fail, switch to the **cluster-diagnostics** skill
  and walk the chain top-down.
