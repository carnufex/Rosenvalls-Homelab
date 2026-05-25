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
.\scripts\cluster-health-report.ps1
```

Use these after:

- first bootstrap
- any rebuild or replace operation
- any routing incident
- any secret-chain incident
- before and after a recovery drill
- before deleting preview namespaces or PVCs

## Operational Scripts

```powershell
.\scripts\cluster-health-report.ps1
.\scripts\export-local-ca.ps1
.\scripts\provision-host1-media-nfs-vm.ps1
.\scripts\seed-homeassistant.ps1
.\scripts\seed-media-configs.ps1
.\scripts\verify-local-routes.ps1
.\scripts\verify-media-nfs.ps1
.\scripts\verify-deluge-vpn.ps1
```

`pvc-seed-utils.ps1` is an internal helper used by seeding scripts. Do not run it directly.

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

## App Status And Node Pressure

Use Grafana as the primary app status view:

- `https://grafana.rosenvall.local/d/homelab-app-status/homelab-app-status`

Fast terminal checks:

```powershell
kubectl top nodes
kubectl top pods -A --sort-by=memory
kubectl get pods -A --field-selector status.phase=Failed
kubectl get events -A --sort-by=.lastTimestamp
```

If Metrics API is unavailable, query Prometheus directly until `metrics-server` has reconciled:

```powershell
$pod = kubectl -n monitoring get pod -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}'
$query = [uri]::EscapeDataString('1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes')
kubectl -n monitoring exec $pod -c prometheus -- wget -qO- "http://127.0.0.1:9090/api/v1/query?query=$query"
```

During Docker cutover, `ragflow` and `matplan-whisper` may be intentionally paused to keep worker memory below eviction pressure. Re-enable them only after media and Home Assistant have run in Kubernetes without new evictions for at least one day.

## Cluster UI

Use Headlamp for live Kubernetes object inspection:

- `https://headlamp.rosenvall.local`
- internal gateway only
- read-only cluster role by default
- shows nodes, namespaces, pods, workload placement, events, PVCs, routes, ArgoCD apps, ExternalSecrets, Longhorn objects, CNPG clusters, and Metrics API CPU/memory data

Use Grafana for history, alerting, and trend dashboards:

- `https://grafana.rosenvall.local/d/homelab-app-status/homelab-app-status`

If Headlamp does not show CPU or memory, verify the Metrics API first:

```powershell
kubectl top nodes
kubectl top pods -A
```

Headlamp is intentionally not an admin console in its first version. Do not grant create, patch, delete, exec, or secret-read permissions without a separate review.

## Authentik Native OIDC

Native OIDC app configuration lives in:

- `kubernetes/infrastructure/controllers/authentik-runtime/README.md`
- `kubernetes/infrastructure/controllers/authentik-runtime/blueprints.yaml`

Current rollout model:

- ArgoCD and Rosenvall DevOps already use Authentik.
- Grafana and Headlamp use Authentik after their GitOps sync completes.
- RAGFlow has an Authentik provider prepared, but app login is not enabled until its OAuth client secret can come from a Kubernetes Secret instead of a ConfigMap.
- Apps without clean native OIDC support stay unchanged. Do not add duplicate local login plus Authentik as the normal path.

## Rosenvall DevOps Preview Cleanup

Preview namespaces created by `rosenvall-devops` are expected to be temporary.

The cleanup job only targets namespaces with:

- label `app.kubernetes.io/part-of=rosenvall-devops-preview`
- age greater than 24 hours
- no annotation `rosenvall.devops/keep=true`

It never deletes the base namespace `devops-previews`. To preserve a preview manually:

```powershell
kubectl annotate namespace <preview-namespace> rosenvall.devops/keep=true
```

Report current candidates without deleting anything:

```powershell
.\scripts\cluster-health-report.ps1
kubectl get namespaces -l app.kubernetes.io/part-of=rosenvall-devops-preview
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
kubectl -n longhorn-system get settings.longhorn.io node-down-pod-deletion-policy orphan-resource-auto-deletion
kubectl get volumes.longhorn.io -n longhorn-system
kubectl -n longhorn-system get orphan -o wide
kubectl get volumeattachment.storage.k8s.io
```

After node restarts, Longhorn can leave stale engine instances or stale Kubernetes `VolumeAttachment` objects. For app PVCs stuck in `ContainerCreating`, match the stuck PVC name to `kubectl -n longhorn-system get orphan -o wide` before deleting anything. Delete only orphan resources of type `engine-instance` that match the affected volume, then recreate the stuck workload pod.

For abrupt power loss, Longhorn should keep `node-down-pod-deletion-policy=delete-deployment-pod`. This allows single-replica Deployment workloads with RWO config PVCs to be recreated on a healthy worker when the original node is down. Do not broaden this to StatefulSets without a separate database/storage review.

Prometheus uses bounded local TSDB storage. If it crashloops with `panic: preallocate: no space left on device`, first expand or repair the Prometheus PVC and restart the pod so filesystem resize can complete. Avoid adding observability PVCs to R2 backup groups unless there is an explicit storage budget decision.

### NFS Media Library

```powershell
kubectl get pv media-library -o yaml
kubectl get ciliumloadbalancerippool first-pool -o jsonpath='{.spec.blocks[0].stop}'
Test-NetConnection 192.168.1.230 -Port 22
Test-NetConnection 192.168.1.230 -Port 2049
.\scripts\verify-media-nfs.ps1
showmount -e 192.168.1.230
```

The Cilium pool stop value must be `192.168.1.229` or lower. `192.168.1.230`
should be owned by VM `8010` (`media-nfs-01`) on `host1`.

In the current host1 layout, the media data is inside VM `100`'s qcow2 disk,
attached to `media-nfs-01` as `scsi1`. VM `100` must stay stopped with
`onboot: 0` while `media-nfs-01` owns the disk. Do not destroy VM `100` with
"destroy unreferenced disks" while it still references the media qcow2 as an
unused disk.

Use `.\scripts\provision-host1-media-nfs-vm.ps1` to recreate or re-bootstrap
the VM. The older host-level NFS scripts are deprecated and require an explicit
escape-hatch flag.

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
