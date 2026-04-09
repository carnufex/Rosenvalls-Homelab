# Operations

Use this page for normal day-2 operations and first-response health checks.

## Access

```powershell
$env:KUBECONFIG = "$PWD\tofu\output\kubeconfig"
$env:TALOSCONFIG = "$PWD\tofu\output\talosconfig"
```

## Core Health Order

Use this order before digging into app-specific symptoms:

1. `kubectl get nodes -o wide`
2. `kubectl get applications.argoproj.io -n argocd`
3. `kubectl get clustersecretstore bitwarden-secretsmanager`
4. `kubectl get externalsecret -A`
5. `kubectl get pods -n cloudflare`
6. `kubectl get certificate -n gateway`
7. `kubectl get gateway -A`
8. `kubectl get httproute -A`

The goal is to validate the bootstrap secret chain and routing chain before spending time on downstream symptoms.

## Core Gates

```powershell
.\scripts\argocd-health-gate.ps1
.\scripts\preflight-core.ps1
```

Use these after:

- first bootstrap
- any rebuild or replace operation
- any routing incident
- any secret-chain incident

## Migration And Cutover Scripts

```powershell
.\scripts\export-local-ca.ps1
.\scripts\bootstrap-media-nfs.ps1 -ClusterSshHost 192.168.1.111 -NodeName desktop -VmId 8010 -VmIp 192.168.1.230
.\scripts\seed-homeassistant.ps1
.\scripts\seed-media-configs.ps1
.\scripts\verify-local-routes.ps1
.\scripts\verify-media-nfs.ps1
.\scripts\verify-deluge-vpn.ps1
```

## High-Value Checks

```powershell
kubectl get pods -A
kubectl get pvc -A
kubectl get events -A --field-selector type=Warning
kubectl get clusters.postgresql.cnpg.io -A
kubectl get volumes.longhorn.io -n longhorn-system
kubectl get gateway -A
kubectl get httproute -A
```

## What Broke

### Routing

```powershell
kubectl get gateway -A
kubectl get httproute -A
.\scripts\verify-local-routes.ps1
```

### PVC Or Longhorn State

```powershell
kubectl get pvc -A
kubectl describe pvc -n media media-library
kubectl get volumes.longhorn.io -n longhorn-system
```

### NFS Media Library

```powershell
kubectl get pv media-library -o yaml
Test-NetConnection 192.168.1.230 -Port 22
Test-NetConnection 192.168.1.230 -Port 2049
.\scripts\verify-media-nfs.ps1
showmount -e 192.168.1.230
```

### Host-Network Apps

```powershell
kubectl get pod -n media -o wide -l app.kubernetes.io/name=plex
kubectl get pod -n homeassistant -o wide -l app.kubernetes.io/name=homeassistant
kubectl logs -n media deploy/plex
kubectl logs -n homeassistant deploy/homeassistant
```

### Deluge VPN

```powershell
kubectl get pod -n media -l app.kubernetes.io/name=deluge-vpn
kubectl logs -n media deploy/deluge-vpn -c wireguard
kubectl logs -n media deploy/deluge-vpn -c deluge
.\scripts\verify-deluge-vpn.ps1
```

## Troubleshooting Priorities

- If `bitwarden-secretsmanager` is not ready, restore that first.
- If public traffic is broken, validate `cloudflared`, the wildcard certificate, and the external gateway before touching app manifests.
- If internal traffic is broken, validate `gateway/internal`, `HTTPRoute` acceptance, and the local CA trust chain before touching workloads.
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
- [Migrations and cutover](../migrations/README.md)
