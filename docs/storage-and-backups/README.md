# Storage And Backups

This page documents the current storage model and the backup posture it enables today.

## Storage Model

- Longhorn is the default persistent storage layer.
- Worker nodes are the effective storage failure domains.
- Talos `EPHEMERAL` storage on the boot disk is separate from the dedicated Longhorn data disk.
- Disk pressure on a node does not automatically mean Longhorn is the problem.

## Longhorn Profiles

| Storage class | Intended use | Notes |
| --- | --- | --- |
| `longhorn` | General workloads | Default class |
| `longhorn-critical` | Critical stateful data | Retained volumes, replica count 2 |
| `longhorn-observability` | Monitoring data | Replica count 2 |

Longhorn keeps:

- `defaultReplicaCount=2`
- strict node-level anti-affinity
- soft zone anti-affinity because this homelab is effectively single-zone
- `allowVolumeCreationWithDegradedAvailability=false`

## Longhorn Backup Posture

- Backup target is configured to Cloudflare R2.
- The repo does not currently define a recurring Longhorn offsite backup policy.
- Treat R2 as configured backup capability, not as proof of a validated restore program.

Implementation notes live in:

- [Longhorn component README](../../kubernetes/infrastructure/storage/longhorn/README.md)

## CloudNativePG Posture

### Authentik

- Backups are scheduled daily.
- Base backups and WAL archives are compressed.
- Restore is explicitly modeled through the `dr-restore` overlay.
- Live backup path: `s3://rosenvall-homelab-backup/authentik/live/`
- DR backup path: `s3://rosenvall-homelab-backup/authentik/dr/`

Implementation notes live in:

- [Authentik DB prerequisites README](../../kubernetes/infrastructure/controllers/authentik-db-prereqs/README.md)

### MatPlan

- A dedicated CNPG cluster exists.
- This repo does not yet document a backup or restore path for MatPlan.
- Treat MatPlan database recovery as an explicit gap until that changes.

## Artifact Backups Outside The Cluster

These are not cluster backups, but they matter for operator recovery:

- `tofu/output/kubeconfig`
- `tofu/output/talosconfig`
- local `terraform.tfvars`

This repo currently does not define a secure off-machine storage policy for those artifacts.

## Practical Triage Notes

- Restore the bootstrap secret chain before starting Longhorn repair work.
- If a node is under `DiskPressure`, inspect the Talos boot disk before assuming Longhorn capacity is the cause.
- Snapshot or back up before filesystem repair work on Longhorn-backed workloads.

## Related Docs

- [Operations](../operations/README.md)
- [Disaster recovery](../disaster-recovery/README.md)
- [Scaling](../scaling/README.md)
