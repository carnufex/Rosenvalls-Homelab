# Authentik Runtime

Authentik is the cluster identity provider for native OIDC integrations.
This directory owns the Authentik Helm release and the blueprint ConfigMap that
creates cluster application providers.

## Native OIDC Apps

| App | Status | Callback / issuer |
| --- | --- | --- |
| ArgoCD | Active | `https://argo.rosenvall.se/api/dex/callback` |
| Rosenvall DevOps | Active | `https://devops.rosenvall.se/auth/callback` |
| Grafana | Active after sync | `https://grafana.rosenvall.local/login/generic_oauth` |
| Headlamp | Active after sync | `https://headlamp.rosenvall.local/oidc-callback` |
| RAGFlow | Provider only | `https://ragflow.rosenvall.local/v1/user/oauth/callback/oidc` |

Use native OIDC only. Do not add an Authentik proxy/outpost for these apps
unless the architecture decision changes.

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
- `RAGFLOW_CLIENT_ID`
- `RAGFLOW_CLIENT_SECRET`

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
- `RAGFlow Users`

The default `profile` scope mapping includes a `groups` claim. Headlamp
Kubernetes RBAC uses the kube-apiserver OIDC group prefix
`authentik:`, so the read-only ClusterRoleBinding references
`authentik:Kubernetes Viewers`.

## RAGFlow Caveat

RAGFlow is not switched to Authentik login yet. The upstream Helm chart writes
`ragflow.service_conf` into a ConfigMap, which would expose the OAuth client
secret if configured directly from GitOps values.

`REGISTER_ENABLED=0` is set to prevent new local sign-ups while this is
pending, but existing local users may still sign in. Treat RAGFlow as
internal-only until its OAuth client secret can be mounted from a Secret or the
chart gains secret-aware OIDC configuration.

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
