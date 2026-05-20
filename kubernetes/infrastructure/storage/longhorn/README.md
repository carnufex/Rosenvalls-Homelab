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

## Backup

- Backup target is configured to Cloudflare R2 (`defaultBackupStore`).
- `RecurringJob/default-hourly-snapshot` keeps 24 hourly local snapshots for volumes in the `default` group.
- `RecurringJob/default-daily-backup` keeps 14 daily offsite backups in R2 for volumes in the `default` group.
- Existing Longhorn volumes are expected to carry `recurring-job-group.longhorn.io/default=enabled`.

## Recovery Expectations

For filesystem inconsistencies, snapshot or back up first and then perform recovery through GitOps changes and runbook steps.
