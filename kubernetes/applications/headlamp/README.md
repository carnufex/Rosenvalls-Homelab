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

The initial deployment is internal-only and read-only. Authentik/OIDC is intentionally left as a follow-up until the client secret and callback contract are created in Bitwarden/Authenik.

Do not switch the chart back to the default `cluster-admin` binding. If write operations are needed later, add a separate admin role bound to a specific Authentik group instead of broadening the default service account.

