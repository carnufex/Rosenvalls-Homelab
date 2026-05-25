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

## Scheduling Contract

- Worker nodes are the storage failure domains in this homelab.
- We do not rely on `topology.kubernetes.io/zone` labels for Longhorn scheduling.
- `replicaSoftAntiAffinity=false` stays strict at the node level so Longhorn prefers one replica per worker.
- `replicaZoneSoftAntiAffinity=true` must stay enabled because unlabeled nodes are treated as the same zone by Longhorn. If this is set to `false`, new 2-replica volumes can get stuck with `ReplicaSchedulingFailure` even when both workers are healthy.
- `allowVolumeCreationWithDegradedAvailability=false` stays enabled so GitOps fails loudly when Longhorn cannot place the requested redundancy.
- `orphanResourceAutoDeletion=instance` is enabled with a `300s` grace period so stale engine or replica runtime instances left by node restarts are cleaned automatically.

## Backup

- Backup target is configured to Cloudflare R2 (`defaultBackupStore`).
- `RecurringJob/default-hourly-snapshot` keeps 24 hourly local snapshots for volumes in the `default` group.
- `RecurringJob/r2-small-config-daily-backup` keeps 3 daily offsite backups in R2 for small config volumes in the `r2-small-config` group.
- `RecurringJob/r2-plex-config-weekly-backup` keeps 1 weekly offsite backup in R2 for the larger Plex config volume in the `r2-plex-config` group.
- R2 backup groups are explicit so the bucket stays within the Cloudflare R2 free tier. The broad `default` group is local snapshots only.

## Recovery Expectations

For filesystem inconsistencies, snapshot or back up first and then perform recovery through GitOps changes and runbook steps.

For attach failures after a node restart:

```powershell
kubectl -n longhorn-system get orphan -o wide
kubectl -n longhorn-system get volume.longhorn.io <volume-name> -o wide
kubectl -n longhorn-system get volumeattachments.longhorn.io <volume-name> -o yaml
kubectl get volumeattachment.storage.k8s.io
```

If a workload PVC is stuck in `attaching` and Longhorn reports an `engine-instance` orphan for the same volume, delete only that matching orphan and let Longhorn reconcile. If Kubernetes still holds a stale `VolumeAttachment` for an old node, delete only the stale attachment object after confirming the replacement pod is scheduled elsewhere.
