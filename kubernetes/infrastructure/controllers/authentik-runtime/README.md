# Authentik Runtime

Authentik is the cluster identity provider for native OIDC integrations.
This directory owns the Authentik Helm release and the blueprint ConfigMap that
creates cluster application providers.

## Capacity Guardrails

The Authentik worker can use several GiB while processing startup and
background-job bursts. It is restricted to nodes labeled
`homelab.rosenvall.se/memory-tier=large`, prefers compute-only nodes, and has a
6Gi memory request with a 7Gi limit. A `LimitRange` and `ResourceQuota` in
`authentik-db-prereqs` provide namespace-level guardrails. Keep at least one
labeled node with 12Gi assigned RAM before rolling out changes that recreate
the worker.

Authentik 2025.10 removed Redis. Do not re-enable the bundled Redis chart or
restore `AUTHENTIK_REDIS__*` settings. Version 2025.10.4 is the minimum allowed
patch because it deletes expired PostgreSQL channel messages in chunks; older
patches can accumulate millions of rows and OOM-loop the worker during
`clean_expired_models`.

## Native OIDC Apps

| App | Status | Callback / issuer |
| --- | --- | --- |
| ArgoCD | Active | `https://argo.rosenvall.se/api/dex/callback` |
| Rosenvall DevOps | Active | `https://devops.rosenvall.se/auth/callback` |
| Grafana | Active after sync | `https://grafana.rosenvall.local/login/generic_oauth` |
| Headlamp | Active | `https://headlamp.rosenvall.se/oidc-callback` |

Use native OIDC for apps in this table. Proxy-based protection is limited to
the explicit exceptions below.

## Secret Contract

OIDC client secrets live in Bitwarden Secrets Manager and are projected into
`authentik-blueprint-secrets`. They must not be written directly to Git.

Required keys:

- `ARGOCD_CLIENT_ID`
- `ARGOCD_CLIENT_SECRET`
- `GRAFANA_CLIENT_ID`
- `GRAFANA_CLIENT_SECRET`
- `HEADLAMP_CLIENT_ID`
- `HEADLAMP_CLIENT_SECRET`
- `SEERR_CLIENT_ID`
- `SEERR_CLIENT_SECRET`
- `PLEX_CLIENT_ID`
- `PLEX_CLIENT_SECRET`

## Authentik Proxy Apps

Plex and Seerr are protected publicly with `oauth2-proxy` because they do not
currently run as clean native Authentik-only OIDC clients in this cluster.
This is an explicit exception from the native-OIDC preference.

If the ExternalSecret is not ready, check the manual
`bitwarden-access-token` secret in namespace `external-secrets` before
debugging Authentik itself.

## Groups

Blueprint-managed groups:

- `ArgoCD Admins`
- `ArgoCD Viewers`
- `Grafana Admins`
- `Grafana Editors`
- `Grafana Viewers`
- `Kubernetes Admins`
- `Kubernetes Viewers`
The default `profile` scope mapping includes a `groups` claim. Headlamp
Kubernetes RBAC uses the kube-apiserver OIDC group prefix
`authentik:`, so the read-only ClusterRoleBinding references
`authentik:Kubernetes Viewers`.

Being an Authentik administrator does not automatically grant access to
applications. App access is controlled by the application-specific groups above,
for example `ArgoCD Admins` or `ArgoCD Viewers` for ArgoCD.

## User Onboarding

Add users from the Authentik admin UI:

1. Open `https://authentik.rosenvall.se/if/admin/`.
2. Go to `Directory -> Users -> Create`.
3. Set username, display name, email, and either an initial password or a reset/invite flow.
4. Add the user to the minimum required groups:
   - `authentik Admins` only for Authentik administrators.
   - `ArgoCD Admins` or `ArgoCD Viewers` for ArgoCD.
   - `Kubernetes Viewers` or `Kubernetes Admins` for Headlamp/Kubernetes UI access.
   - `Grafana Admins`, `Grafana Editors`, or `Grafana Viewers` for Grafana.

Apps with `policy_engine_mode: any` and no group binding are available to any
authenticated Authentik user. Add policy bindings before granting access to
broader user populations.

## Verification

```powershell
$env:KUBECONFIG = "$PWD\tofu\output\kubeconfig"

kubectl -n authentik get externalsecret authentik-blueprint-secrets
kubectl -n authentik get pods
kubectl -n kube-system get pod kube-apiserver-control-01 -o jsonpath='{.spec.containers[0].command}'
kubectl -n monitoring get externalsecret grafana-oauth
kubectl -n headlamp get externalsecret headlamp-oidc
```

The kube-apiserver command should include:

- `--oidc-issuer-url=https://authentik.rosenvall.se/application/o/headlamp/`
- `--oidc-client-id=headlamp`
- `--oidc-groups-prefix=authentik:`
