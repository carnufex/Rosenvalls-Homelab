# Longhorn Storage

This directory contains the configuration for Longhorn, a distributed block storage system for Kubernetes.

## Configuration

- Namespace: `longhorn-system`
- Default replica policy: `2`
- Metrics: ServiceMonitor enabled for `kube-prometheus-stack`
- UI route: `https://longhorn.rosenvall.local` (internal gateway)
- Failure domain model: single-zone homelab, multi-node storage

## Storage Profiles

- `longhorn` (default): general workloads
- `longhorn-critical`: critical stateful data, retained volumes, replica count 2
- `longhorn-observability`: monitoring data, replica count 2
- `longhorn-observability-single`: disposable/high-churn monitoring data, replica count 1; Prometheus TSDB must not consume critical rebuild capacity
- `longhorn-single`: replica count 1 for workloads that replicate their own data (CNPG clusters with `instances >= 2`, e.g. ngm)

## Scheduling Contract

- Worker nodes are the storage failure domains in this homelab.
- We do not rely on `topology.kubernetes.io/zone` labels for Longhorn scheduling.
- `replicaSoftAntiAffinity=false` stays strict at the node level so Longhorn prefers one replica per worker.
- `replicaZoneSoftAntiAffinity=true` must stay enabled because unlabeled nodes are treated as the same zone by Longhorn. If this is set to `false`, new 2-replica volumes can get stuck with `ReplicaSchedulingFailure` even when both workers are healthy.
- `allowVolumeCreationWithDegradedAvailability=false` stays enabled so GitOps fails loudly when Longhorn cannot place the requested redundancy.
- `orphanResourceAutoDeletion=instance` is enabled with a `300s` grace period so stale engine or replica runtime instances left by node restarts are cleaned automatically.
- `nodeDownPodDeletionPolicy=delete-deployment-pod` lets Longhorn delete workload pods from down nodes so single-replica Deployment apps with RWO config PVCs can be recreated on a healthy worker after abrupt power loss.

## Backup

Recurring-job groups (`recurring-jobs.yaml`). A volume joins a group through the label
`recurring-job-group.longhorn.io/<group>: enabled` on its PVC (with
`recurring-job.longhorn.io/source: enabled`, Longhorn copies PVC labels to the volume) or
directly on the Longhorn volume; volumes without any recurring-job label are `default`.

| Group | Members | Jobs |
| --- | --- | --- |
| `default` | app config and data | snapshot 02:30 keep 2, backup 03:00 keep 7, trim Sun 04:00 |
| `cnpg` | CloudNativePG data + WAL PVCs (`spec.inheritedMetadata` on each Cluster) | trim only |
| `disposable` | Prometheus TSDB, Loki | trim only |

- `BackupTarget/default` is `nfs://192.168.1.230:/srv/nfs/backup/longhorn`: host1's 8 TB
  `lagring` disk, exported by the Proxmox host (`scripts/configure-host1-backup-nfs.ps1`).
  It is outside every Longhorn data disk and outside `desktop`, the host of all three storage
  workers. Not R2: Class A operations exceed the free tier.
- Only two local snapshots: seven daily snapshots of churny volumes pinned overwritten blocks
  until a 10 GiB volume used 22 GiB and a 5 GiB Prometheus TSDB 48 GiB of node disk, which
  filled worker disks and failed replicas (2026-10-11). History lives in the backups now.
- CNPG volumes are not snapshotted: a crash-consistent data snapshot without a matching WAL
  snapshot is not restorable. authentik, cmdb and lots run nightly `pg_dump` CronJobs
  (`db-dump.yaml`) to `/srv/nfs/backup/db-dumps/<namespace>` (14 days); ngm dumps to OneDrive.
  CNPG only applies `inheritedMetadata` to new PVCs; existing PVCs were labelled by hand.
- Moving a volume to another group leaves the old group's snapshots behind (no retention
  applies any more); delete them by hand.
- Disposable volumes and multi-instance CNPG volumes run with `numberOfReplicas: 1`. Volumes
  created before that class existed were patched on the Longhorn volume directly.

Restore a Longhorn backup: Longhorn UI -> Backup -> volume -> Restore (new volume), then bind
a PV/PVC to it. Restore a database dump:
`pg_restore --clean --if-exists --no-owner -d <db> <namespace>-<timestamp>.dump`.

## Recovery Expectations

For filesystem inconsistencies, snapshot or back up first and then perform recovery through GitOps changes and runbook steps. A workload can be `Running` while its mounted filesystem returns `Input/output error`; in that case the safest first step is usually a single pod remount, followed by filesystem repair or Longhorn restore only if the error persists.

For unplanned power loss:

- If one worker goes down, Deployment-based apps such as Radarr, Sonarr, Seerr, Jackett, Deluge, Plex, and the app proxies should be recreated on a remaining healthy worker when their Longhorn volumes can attach there.
- If several workers go down, 2-replica Longhorn volumes remain recoverable as long as at least one healthy replica for the volume is available. Some apps may wait until a worker that holds a replica returns.
- If all nodes go down, the cluster cannot serve workloads during the outage, but Longhorn should recover volume state when the cluster and at least one replica per volume come back.
- If a node is permanently lost, replace it and let Longhorn rebuild replicas before starting another risky maintenance operation.

For attach failures after a node restart:

```powershell
kubectl -n longhorn-system get settings.longhorn.io node-down-pod-deletion-policy orphan-resource-auto-deletion
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n longhorn-system get orphan -o wide
kubectl -n longhorn-system get volume.longhorn.io <volume-name> -o wide
kubectl -n longhorn-system get volumeattachments.longhorn.io <volume-name> -o yaml
kubectl get volumeattachment.storage.k8s.io
```

If a workload PVC is stuck in `attaching` and Longhorn reports an `engine-instance` orphan for the same volume, delete only that matching orphan and let Longhorn reconcile. If Kubernetes still holds a stale `VolumeAttachment` for an old node, delete only the stale attachment object after confirming the replacement pod is scheduled elsewhere.

After power returns, run:

```powershell
.\scripts\post-power-loss-check.ps1
```

The check fails on stuck Longhorn volumes or engine-instance orphans, warns on degraded attached volumes and replica orphans, and also verifies ArgoCD, ExternalSecrets, routes, media NFS, and Deluge VPN.
