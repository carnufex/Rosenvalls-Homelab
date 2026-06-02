# Disaster Recovery

This page documents the current recovery posture as it actually exists today.

## Verified, Partial, Missing

Verified from the current cluster health pass:

- Kubernetes API is reachable through the local kubeconfig.
- 5/5 nodes are `Ready`.
- No pods were outside `Running` or `Succeeded`.
- `ClusterSecretStore/bitwarden-secretsmanager` and current `ExternalSecret` resources were `Ready`.
- Longhorn power-loss recovery settings matched expectations.
- Attached Longhorn volumes were healthy with no stuck attaching/detaching volumes or Longhorn orphans.
- `rosenvall-devops` was `Synced Healthy`.
- Metrics API answered `kubectl top nodes` and `kubectl top pods -A`.

Partially verified:

- `ragflow-helm` was `OutOfSync Healthy` and needs follow-up before the cluster is considered fully clean.
- Longhorn local snapshots exist, but active offsite backup is paused until local MinIO or another non-R2 backend is added.
- Media NFS has verification scripts and documentation, but media files still need a separate file-level backup policy.
- Authentik has a historical CNPG restore overlay, but active R2 WAL/base backups are disabled and a new local backup target is required.

Missing or residual risk:

- MatPlan and BikePal runtime manifests exist, but database restore is not yet proven end to end.
- Talos API CA rotation is not complete until a dry-run and live rotation succeed all the way through.
- Secure off-machine storage for current kubeconfig, talosconfig, local `terraform.tfvars`, and exported local CA must be maintained outside Git.

## Recovery Modes

### Cold Rebuild

Use this when the server is replaced, lost, or stolen and you are willing to rebuild the cluster from code.

What Git gives you:

- Proxmox VM definitions
- Talos machine configuration generation
- GitOps manifests
- bootstrap procedure
- documented Authentik restore overlay

What Git does not give you:

- Proxmox credentials
- `bitwarden-access-token`
- Cloudflare dashboard-side tunnel publishing
- local `terraform.tfvars`
- an off-machine copy of `tofu/output/kubeconfig`
- an off-machine copy of `tofu/output/talosconfig`

### State-Preserving Recovery

Use this when you need more than a fresh rebuild, for example preserving existing access paths, identities, or database history with the least disruption.

This is only partially documented today. Authentik has a restore story. Several other stateful workloads do not.

### Post Power-Loss Restart

Use this after a breaker trip, abrupt node shutdown, or whole-cluster power outage where the hardware comes back and the cluster should recover in place.

```powershell
$env:KUBECONFIG = (Resolve-Path .\tofu\output\kubeconfig)
.\scripts\post-power-loss-check.ps1
```

Expected behavior:

- one worker down: Deployment workloads with RWO Longhorn config PVCs should be recreated on a healthy worker when a healthy replica is available
- several workers down: apps recover when at least one usable replica for each needed volume is available
- all nodes down: the cluster is unavailable during the outage, then should recover when the control plane, workers, Longhorn managers, and at least one replica per volume return

The script fails on core bootstrap/routing failures, stuck Longhorn volumes, engine-instance orphans, bad ExternalSecrets, unhealthy core ArgoCD apps, media NFS failure, or Deluge VPN failure. It warns on known non-blocking cleanup candidates such as allowed `ragflow-helm` drift or orphan PVC review candidates.
It also removes terminal non-Job controller pods left by node shutdown before running the final health report, because replacement workloads are the authoritative recovery signal after an outage. Job history is left intact.

Drill evidence on 2026-05-25: `worker-04` was rebooted with Talos `--mode powercycle` and no Kubernetes drain while it hosted Radarr, Sonarr, Seerr, Jackett, and Deluge config PVCs. The node moved through `Ready=False/Unknown`, Longhorn media config volumes moved through `attaching/unknown`, and all media pods returned to `Running` with the volumes `attached/healthy` without manual orphan or `VolumeAttachment` cleanup. `post-power-loss-check.ps1` then passed after removing shutdown-generated terminal controller pods.

Full-cluster power-cycle drill evidence on 2026-05-25: all Talos nodes were rebooted with `--mode powercycle` and no Kubernetes drain. Talos and Kubernetes recovered, media workloads and RWO Longhorn config PVCs recovered, and post-outage cleanup removed terminal controller pods left by node shutdown. Prometheus required a longer startup probe because WAL replay exceeded the default startup window during full-cluster recovery; monitoring retention is intentionally bounded because observability history is less critical than successful restart.

## New Server Or Stolen Server Runbook

1. Prepare the replacement server and restore Proxmox access.
2. Restore or recreate local `tofu/terraform.tfvars`.
3. Run `tofu init`, `tofu plan`, and `tofu apply`.
4. Export `TALOSCONFIG` and `KUBECONFIG` from `tofu/output/`.
5. Verify Talos and Kubernetes API health.
6. Restore the manual `bitwarden-access-token` path or pass it into `bootstrap.ps1`.
7. Run `bootstrap.ps1`.
8. Run `.\scripts\argocd-health-gate.ps1` and `.\scripts\preflight-core.ps1`.
9. Restore application state only where backup and restore paths are documented.
10. Rotate secrets and external credentials if the old server was stolen or otherwise untrusted.
11. Run `.\scripts\cluster-health-report.ps1` and resolve every failure before declaring recovery complete.

## Restore Matrix

| Area | Current posture | Notes |
| --- | --- | --- |
| Core cluster bootstrap | Strong | OpenTofu + Talos + `bootstrap.ps1` are codified |
| Secret chain bootstrap | Manual dependency | Requires `bitwarden-access-token` |
| Public routing | Partial | In-cluster connector is in Git, published routes are dashboard-managed |
| Authentik database | Partial | Active R2 backups are disabled; add local MinIO before relying on restore |
| Longhorn volumes | Partial | Local snapshots exist; active offsite backup is disabled to avoid R2 Class A costs |
| MatPlan data | Weak | Runtime is defined, restore path is not documented |
| Talos/Kubernetes access artifacts | Weak | Generated locally, no repo-defined off-machine backup policy |
| Headlamp cluster UI | Internal read-only | Helps inspect recovery state, but is not part of bootstrap |
| DevOps preview namespaces | Automated TTL cleanup | Non-critical previews older than 24h are deleted by label-based cleanup |

## Bootstrap Secret Recovery

If `ClusterSecretStore/bitwarden-secretsmanager` is not `Ready`, recreate the bootstrap secret first:

```powershell
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-secrets create secret generic bitwarden-access-token --from-literal=token=<token> --dry-run=client -o yaml | kubectl apply -f -
kubectl get clustersecretstore bitwarden-secretsmanager
kubectl get externalsecret -A
```

This should restore downstream secret materialization for Cloudflare, cert-manager, ArgoCD, Authentik, and backup credentials.

## Routing Recovery

Validate this chain in order:

```powershell
kubectl get pods -n cloudflare
kubectl get certificate -n gateway
kubectl get gateway -n gateway external -o yaml
kubectl get httproute -A
```

If the wildcard route still fails while the cluster objects are healthy, inspect the Cloudflare dashboard-side published route and confirm `Match SNI to Host` is enabled.

## Authentik Restore

Authentik is the best-documented restore path in the repo today.

- default mode: `initdb`
- restore mode: switch to the `dr-restore` overlay under `authentik-db-prereqs`
- historical live backups: `s3://rosenvall-homelab-backup/authentik/live/`
- DR overlay writes to: `s3://rosenvall-homelab-backup/authentik/dr/`

Default live-cluster writes to R2 are disabled. Do not treat the historical R2 prefix as current unless a fresh backup inventory confirms a usable recovery point.

Do not mix backup prefixes between fresh bootstrap and DR-restored clusters.

## What Must Exist Outside Git

- Proxmox credentials
- Bitwarden access token
- Cloudflare tunnel and published route ownership
- Cloudflare DNS API token contract
- R2 credentials
- local `terraform.tfvars`
- current `tofu/output/kubeconfig`
- current `tofu/output/talosconfig`
- exported `gateway-local-ca`

Store access artifacts in a password manager or encrypted offline recovery bundle. Do not put generated access files back in Git.

## Recovery Drill Checklist

Run this drill after bootstrap changes, Talos/OpenTofu changes, or security cleanup:

```powershell
$env:KUBECONFIG = "$PWD\tofu\output\kubeconfig"
.\scripts\preflight-core.ps1
.\scripts\argocd-health-gate.ps1
.\scripts\cluster-health-report.ps1
.\scripts\verify-media-nfs.ps1
.\scripts\verify-deluge-vpn.ps1
```

For state restore drills, use non-production restore targets first:

- restore one small Longhorn-backed config PVC from backup into a temporary namespace
- restore Authentik with the documented `dr-restore` overlay in a controlled window
- verify MatPlan and BikePal CNPG backup/restore before treating those databases as recoverable
- verify media files through NFS and a separate file-level backup, not through Longhorn

## Talos API CA Status

Kubernetes access artifacts can be regenerated and rotated, but Talos API CA rotation remains a separate item. Do not mark stolen-server recovery complete until Talos API CA rotation has either succeeded or the affected Talos nodes have been rebuilt from trusted configuration.

## Priority Backlog

- `P0`: write a fully validated new-server and stolen-server runbook from bare metal to green core gate
- `P1`: verify restore stories for each stateful system and document where restore is only theoretical
- `P2`: codify Longhorn backup policy, add a MatPlan restore story, reduce dashboard-only dependencies, and evaluate a more HA control plane

## Related Docs

- [Getting started](../getting-started/README.md)
- [Operations](../operations/README.md)
- [Networking](../networking/README.md)
- [Storage and backups](../storage-and-backups/README.md)
