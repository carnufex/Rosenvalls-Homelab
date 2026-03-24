# Cluster Diagnostics

Use this guide when investigating cluster health in `Rosenvalls-Homelab`.

## Order Of Operations

1. Export `KUBECONFIG` from `tofu/output/kubeconfig`.
2. Check nodes and ArgoCD applications.
3. Check `ClusterSecretStore/bitwarden-secretsmanager`.
4. Check all `ExternalSecret` resources.
5. Check `cloudflared`, wildcard certificate, and Gateway status.
6. Check `HTTPRoute` acceptance.
7. Only then investigate app-specific or storage-specific failures.

## High-Value Commands

```powershell
kubectl get nodes -o wide
kubectl get applications.argoproj.io -n argocd
kubectl get clustersecretstore
kubectl get externalsecret -A
kubectl get pods -A
kubectl get certificate -A
kubectl get gateway -A
kubectl get httproute -A
```

## Important Context

- `bitwarden-access-token` is a manual bootstrap secret in `external-secrets`.
- If that secret is missing, many downstream failures are symptoms, not root causes.
- Public traffic reaches apps through Cloudflare Tunnel to `gateway/external`.
