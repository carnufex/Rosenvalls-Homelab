# Storage And Backups

This page documents the current storage model and the backup posture it enables today.

## Storage Model

- Longhorn is the default persistent storage layer for app state.
- Worker nodes are the effective storage failure domains.
- Talos `EPHEMERAL` storage on the boot disk is separate from the dedicated Longhorn data disk.
- The media library is not stored in Longhorn.

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

## Media Library Model

The media library now lives on a dedicated helper VM instead of inside Longhorn.

Current target:

- VM: `media-nfs-01`
- IP: `192.168.1.230`
- disk: `WD-red`
- export path: `/srv/nfs/media`
- Kubernetes PV: `media-library`
- Kubernetes PVC: `media/media-library`

Expected directories:

- `downloads`
- `tv`
- `movies`
- `familjefilmer`

Radarr, Sonarr, and Deluge keep using `/lagring` inside the container so historical paths continue to work.

Plex mounts the same export as:

- `/tv`
- `/movies`
- `/familjefilmer`

## Backup Posture

### Longhorn-Backed Config PVCs

Longhorn should back up these PVCs:

- `homeassistant/homeassistant-config`
- `media/jackett-config`
- `media/radarr-config`
- `media/sonarr-config`
- `media/overseerr-config`
- `media/plex-config`
- `media/deluge-config`

This repo does not yet define a Longhorn recurring backup resource for each of them, so treat this as an operator requirement and verify the schedule in Longhorn after applying.

### NFS Media Library

The NFS export on `192.168.1.230` is outside Longhorn.

That means:

- Longhorn backups do not protect the media files
- the NFS VM needs its own file-level backup or `rsync` policy
- the old Docker host can be treated as the temporary migration source, not as a durable backup

### Cluster Access Artifacts

These are not cluster backups, but they matter for operator recovery:

- `tofu/output/kubeconfig`
- `tofu/output/talosconfig`
- local `terraform.tfvars`
- exported copy of `gateway-local-ca`

Store them outside Git and outside the cluster.

## Practical Triage Notes

- Restore the bootstrap secret chain before starting Longhorn repair work.
- If a node is under `DiskPressure`, inspect the Talos boot disk before assuming Longhorn capacity is the cause.
- Use `.\scripts\verify-media-nfs.ps1` before blaming app mounts for media-library issues.
- Snapshot or back up before filesystem repair work on Longhorn-backed workloads.

## Related Docs

- [Operations](../operations/README.md)
- [Disaster recovery](../disaster-recovery/README.md)
- [Scaling](../scaling/README.md)
- [Migrations and cutover](../migrations/README.md)
