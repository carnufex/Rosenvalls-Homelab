# Operations

Use this page for normal day-2 operations and first-response health checks.

## Access

```powershell
$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
$env:TALOSCONFIG = "$PWD/tofu/output/talosconfig"
```

## Core Health Order

Use this order before digging into app-specific symptoms:

1. `kubectl get nodes -o wide`
2. `kubectl get applications.argoproj.io -n argocd`
3. `kubectl get clustersecretstore bitwarden-secretsmanager`
4. `kubectl get externalsecret -A`
5. `kubectl get pods -n cloudflare`
6. `kubectl get certificate -n gateway cert-wildcard`
7. `kubectl get gateway -n gateway external -o yaml`
8. `kubectl get httproute -A`

The goal is to validate the bootstrap secret chain and routing chain before spending time on downstream symptoms.

## Core Gates

```powershell
$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
.\scripts\argocd-health-gate.ps1
.\scripts\preflight-core.ps1
```

Use these after:

- first bootstrap
- any rebuild or replace operation
- any routing incident
- any secret-chain incident

## Daily Access

Basic node check:

```powershell
kubectl get nodes
```

ArgoCD bootstrap password:

```powershell
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | %{[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))}
```

Local ArgoCD port-forward:

```powershell
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

## High-Value Checks

```powershell
kubectl get pods -A
kubectl get pvc -A
kubectl get clusters.postgresql.cnpg.io -A
kubectl get volumes.longhorn.io -n longhorn-system
kubectl get gateway -A
kubectl get httproute -A
```

## Troubleshooting Priorities

- If `bitwarden-secretsmanager` is not ready, restore that first.
- If public traffic is broken, validate `cloudflared`, the wildcard certificate, and the external gateway before touching app manifests.
- If storage is degraded, verify the secret chain and routing chain are already green before starting Longhorn repair work.
- If a node shows `DiskPressure`, inspect the Talos boot disk and `EPHEMERAL` usage before blaming Longhorn.

## Naming Conventions In The Docs

- Use `<control-plane-node>` and `<worker-node>` as placeholders in procedures.
- Use `control-01` and `worker-01` only when a concrete example is required.

## Related Docs

- [Disaster recovery](../disaster-recovery/README.md)
- [Scaling](../scaling/README.md)
- [Networking](../networking/README.md)
- [Storage and backups](../storage-and-backups/README.md)
