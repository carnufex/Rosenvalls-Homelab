# Headlamp

Headlamp is the internal Kubernetes UI for quick cluster inspection.

## Access Model

- URL: `https://headlamp.rosenvall.local`
- Route: `gateway/internal` only
- Service type: `ClusterIP`
- Default permissions: read-only cluster visibility through `ClusterRole/headlamp-readonly`
- No delete, patch, create, exec, or secret-read permission is granted by this app.

Headlamp complements Grafana. Use Headlamp to inspect live Kubernetes objects and use Grafana for history, dashboards, alerts, and capacity trends.

## What It Can Show

- node readiness and node-level metrics
- namespaces and workload placement
- pods, deployments, statefulsets, daemonsets, jobs, and cronjobs
- services, routes, gateways, ingresses, and network policies
- PVCs, PVs, storage classes, Longhorn objects, and CNPG clusters
- ArgoCD application state and ExternalSecret readiness

The UI uses the existing Metrics API, so `kubectl top nodes` and `kubectl top pods -A` should work before expecting CPU and memory graphs in Headlamp.

## Auth Status

Headlamp uses Authentik OIDC with callback `https://headlamp.rosenvall.local/oidc-callback`.
Kubernetes API authentication must accept the Authentik issuer
`https://authentik.rosenvall.se/application/o/headlamp/` and map the `groups`
claim with the `authentik:` prefix.

Read-only access is bound to the Authentik group `Kubernetes Viewers`, which
appears to Kubernetes as `authentik:Kubernetes Viewers`. The Headlamp service
account is intentionally not bound to cluster read permissions.

Do not switch the chart back to the default `cluster-admin` binding. If write operations are needed later, add a separate admin role bound to a specific Authentik group instead of broadening the default service account.

