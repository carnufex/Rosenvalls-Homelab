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

The media library is outside Longhorn and is served over NFS from a dedicated VM on the Proxmox host that owns the media disk.

Current target:

- Proxmox host: `host1`
- VM: `media-nfs-01`
- VMID: `8010`
- IP: `192.168.1.230`
- disk/storage: `lagring` on `host1`
- data disk: existing VM `100` qcow2 disk `lagring:100/vm-100-disk-0.qcow2`, attached to `media-nfs-01` as `scsi1`
- export path: `/srv/nfs/media`, mounted from the existing ext4 partition
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

Persistence and backup are intentionally separate concerns:

- a pod restart or node reboot should not lose settings because app state lives on Longhorn PVCs
- a single worker failure should not lose settings because Longhorn keeps two replicas on worker disks
- a full Longhorn loss, accidental volume deletion, ransomware, or operator mistake still requires restore from backup

### Longhorn-Backed Config PVCs

Longhorn should back up these PVCs:

- `homeassistant/homeassistant-config`
- `media/jackett-config`
- `media/radarr-config`
- `media/sonarr-config`
- `media/overseerr-config`
- `media/plex-config`
- `media/deluge-config`

Longhorn is configured with:

- hourly local snapshots for the `default` recurring-job group, retained for 24 snapshots
- daily offsite backups to the configured Cloudflare R2 backup target, retained for 14 backups

Existing Longhorn volumes are expected to carry `recurring-job-group.longhorn.io/default=enabled`. Verify this in Longhorn after applying if a PVC is especially important.

### NFS Media Library

The NFS export on `192.168.1.230` is outside Longhorn.

That means:

- Longhorn backups do not protect the media files
- the media disk needs its own file-level backup or `rsync` policy
- the old Docker host can be treated as the temporary migration source, not as a durable backup
- do not destroy VM `100` with "destroy unreferenced disks" while it still has an `unused` reference to the media qcow2

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
