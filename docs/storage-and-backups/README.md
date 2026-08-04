# Storage And Backups

This page documents the current storage model and the backup posture it enables today.

## Storage Model

- Longhorn is the default persistent storage layer for app state.
- Worker nodes are the effective storage failure domains.
- Talos `EPHEMERAL` storage on the boot disk is separate from the dedicated Longhorn data disk.
- The media library is not stored in Longhorn.
- The Immich library is not stored in Longhorn.

## Longhorn Profiles

| Storage class | Intended use | Notes |
| --- | --- | --- |
| `longhorn` | General workloads | Default class |
| `longhorn-critical` | Critical stateful data | Retained volumes, replica count 2 |
| `longhorn-observability` | Monitoring data | Replica count 2 |

Longhorn keeps:

- `defaultReplicaCount=2`
- strict node-level anti-affinity
- soft zone anti-affinity while `host1` has limited Longhorn capacity
- `allowVolumeCreationWithDegradedAvailability=false`

Kubernetes nodes should carry `homelab.rosenvall.se/proxmox-host` and
`topology.kubernetes.io/zone` labels for the physical Proxmox host. Those labels
allow workloads and Longhorn replica placement to become host-aware. Do not make
zone anti-affinity strict until `host1` has enough Longhorn disk capacity, or
new 2-replica volumes can fail to schedule.

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

## Immich Library Model

Immich uses a separate NFS VM and disk from the media stack:

- Proxmox host: `desktop`
- VM: `nfs-01`
- VMID: `8011`
- IP: `192.168.1.231`
- data disk: 2 TiB allocation on the 4 TB WD Red storage
- export path: `/srv/nfs/immich`
- Kubernetes PV: `immich-library-wd-red`
- Kubernetes PVC: `immich/immich-library-wd-red`

The media NFS export at `192.168.1.230:/srv/nfs/media` is unrelated and must
not be used by Immich.

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
- `media/overseerr-config` (Seerr config PVC, name retained from the Overseerr migration)
- `media/plex-config`
- `media/deluge-config`

Longhorn is configured with:

- hourly local snapshots for the `default` recurring-job group, retained for 24 snapshots

Active Longhorn and CNPG R2 backups are disabled. Cloudflare R2 exceeded the free Class A operation allowance when it was used as an active Longhorn and CNPG backup target. Do not point Longhorn, CNPG, or any high-frequency backup process at R2 unless there is an explicit budget decision.

Config PVCs should carry `recurring-job.longhorn.io/source=enabled` plus `recurring-job-group.longhorn.io/default=enabled` for local snapshots only. The next primary backup target should be local S3-compatible storage, such as MinIO on a disk outside Longhorn's own data disks.

R2 is reserved for low-frequency critical DR only. The live R2 policy is:

- monthly Authentik logical dump under encrypted `critical-dr/authentik/<yyyy-mm>/`
- monthly slim app config archive under encrypted `critical-dr/app-configs/<yyyy-mm>/`
- manual encrypted bootstrap DR kit under `critical-dr/bootstrap/<yyyy-mm>/`
- three monthly copies retained for each critical category
- no media files, generated metadata, cache, thumbnails, Longhorn volume backups, CNPG WAL archives, or general app data

Slim app config means restore-relevant configuration only. It includes Home Assistant, Plex, Radarr, Sonarr, Seerr, Jackett, and Deluge configuration files and local app databases, but excludes Plex metadata/cache/codecs/logs, Radarr/Sonarr media covers/logs/backups, and generated cache directories.

Keep R2 well below the free-tier limits for both storage and Class A operations.

Audit R2 risk with:

```powershell
.\scripts\r2-backup-audit.ps1
```

Build and inspect critical R2 artifacts with:

```powershell
.\scripts\build-r2-dr-kit.ps1
.\scripts\r2-critical-inventory.ps1
```

### NFS Media Library

The NFS export on `192.168.1.230` is outside Longhorn.

That means:

- Longhorn backups do not protect the media files
- the media disk needs its own file-level backup or `rsync` policy
- the old Docker host can be treated as the temporary migration source, not as a durable backup
- do not destroy VM `100` with "destroy unreferenced disks" while it still has an `unused` reference to the media qcow2

### Immich Library

The WD Red NFS export on `192.168.1.231` is also outside Longhorn. There is no
automated backup for it today. Immich's database backups under `/data/backups`
share the same disk and do not protect against disk loss; retain the original
photos elsewhere until an independent backup is configured.

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
